use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use nix::unistd::mkfifo;
use rand::RngCore;
use std::collections::HashSet;
use std::fs::{self, File};
use std::os::unix::fs::symlink;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use tempfile::{NamedTempFile, TempDir};
use walkdir::WalkDir;

#[derive(Parser, Debug)]
#[command(author, version, about = "wcat test + tooling harness", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Run the regression suite (default)
    Tests {
        /// Only run tests whose name contains this filter
        #[arg(short, long)]
        filter: Option<String>,
        /// Print per-test execution details
        #[arg(short, long, default_value_t = false)]
        verbose: bool,
    },
    /// Rewrite .asm files into processed/ without stripping pure comment lines
    ProcessAsm {
        /// Output directory (defaults to processed)
        #[arg(short, long, default_value = "processed")]
        output: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let command = cli.command.unwrap_or(Commands::Tests {
        filter: None,
        verbose: false,
    });

    match command {
        Commands::Tests { filter, verbose } => {
            VERBOSE.store(verbose, Ordering::Relaxed);
            run_tests(filter)
        }
        Commands::ProcessAsm { output } => process_asm(output),
    }
}

// --------------------- Shared harness --------------------------------------
struct Harness {
    wcat: PathBuf,
    cat: PathBuf,
    fixtures: Fixtures,
}

type TestCase = (&'static str, Box<dyn Fn(&Harness) -> Result<()>>);

static VERBOSE: AtomicBool = AtomicBool::new(false);

impl Harness {
    fn new() -> Result<Self> {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .context("expected test/ to have a parent")?
            .to_path_buf();
        let wcat = root.join("wcat/wcat");
        let cat = which::which("cat").context("system cat not found")?;

        ensure_wcat_built(&root, &wcat)?;
        let fixtures = Fixtures::new()?;

        Ok(Self {
            wcat,
            cat,
            fixtures,
        })
    }

    fn compare_with_cat(&self, args: &[&str], input: Option<&[u8]>) -> Result<()> {
        let wcat_out = run_cmd_with_arg0(&self.wcat, args, input, Some(&self.cat))?;
        let cat_out = run_cmd(&self.cat, args, input)?;
        if wcat_out.stdout != cat_out.stdout
            || wcat_out.stderr != cat_out.stderr
            || wcat_out.status.code() != cat_out.status.code()
        {
            bail!(
                "output mismatch for args {:?}\n=== wcat stdout ===\n{}\n=== cat stdout ===\n{}\n=== wcat stderr ===\n{}\n=== cat stderr ===\n{}\n=== wcat status ===\n{:?}\n=== cat status ===\n{:?}",
                args,
                String::from_utf8_lossy(&wcat_out.stdout),
                String::from_utf8_lossy(&cat_out.stdout),
                String::from_utf8_lossy(&wcat_out.stderr),
                String::from_utf8_lossy(&cat_out.stderr),
                wcat_out.status.code(),
                cat_out.status.code()
            );
        }
        self.compare_output_files_with_cat(args, input)?;
        Ok(())
    }

    fn compare_output_files_with_cat(&self, args: &[&str], input: Option<&[u8]>) -> Result<()> {
        let wcat_file = NamedTempFile::new_in(self.fixtures.dir.path())?;
        let cat_file = NamedTempFile::new_in(self.fixtures.dir.path())?;
        run_cmd_to_file(
            &self.wcat,
            args,
            input,
            Some(&self.cat),
            wcat_file.path(),
        )?;
        run_cmd_to_file(&self.cat, args, input, None, cat_file.path())?;
        let wcat_bytes = fs::read(wcat_file.path())?;
        let cat_bytes = fs::read(cat_file.path())?;
        if wcat_bytes != cat_bytes {
            bail!(
                "file output mismatch for args {:?} (wcat {}B vs cat {}B)",
                args,
                wcat_bytes.len(),
                cat_bytes.len()
            );
        }
        Ok(())
    }
}

struct Fixtures {
    dir: TempDir,
    sample_a: PathBuf,
    sample_b: PathBuf,
    blank: PathBuf,
    tabs: PathBuf,
    mixed: PathBuf,
    stdin_data: Vec<u8>,
    stdin_mix: Vec<u8>,
    dash_name: PathBuf,
    option_like: PathBuf,
    dash_v_file: PathBuf,
    empty: PathBuf,
    no_newline: PathBuf,
    large: PathBuf,
    huge: PathBuf,
    control: PathBuf,
    binary: PathBuf,
    dir_path: PathBuf,
}

impl Fixtures {
    fn new() -> Result<Self> {
        let dir = TempDir::new()?;
        let base = dir.path().to_path_buf();
        let p = |name: &str| base.join(name);

        fs::write(p("a.txt"), b"alpha\n")?;
        fs::write(p("b.txt"), b"beta\n")?;
        fs::write(p("blank.txt"), b"one\n\n\nthree\n\n\n")?;
        fs::write(p("tabs.txt"), b"col1\tcol2\nline\t2\n")?;
        fs::write(p("mixed.txt"), b"tab\t\x01\nline\t2\x7f\n")?;
        let stdin_data = b"stdin data\n".to_vec();
        let stdin_mix = b"middle line\n".to_vec();
        fs::write(p("-dash.txt"), b"dash file\n")?;
        fs::write(p("-n"), b"option-looking file\n")?;
        fs::write(p("-vfile.txt"), b"dash-v data\n")?;
        fs::write(p("empty.txt"), b"")?;
        fs::write(p("no_newline.txt"), b"no newline")?;
        fs::write(
            p("large.txt"),
            (1..=3000)
                .map(|i| format!("line {i}\n"))
                .collect::<String>(),
        )?;
        // Keep "huge" large enough to hit big-input paths but small enough to avoid pipe stalls.
        fs::write(
            p("huge.txt"),
            (1..=1000)
                .map(|i| format!("line {i}\n"))
                .collect::<String>(),
        )?;
        fs::write(
            p("control.txt"),
            b"plain\ncontrol:\x01here\nesc:\x1bX\nmeta:\x80Y\n",
        )?;
        let mut binary = vec![0u8; 512];
        rand::thread_rng().fill_bytes(&mut binary);
        fs::write(p("binary.bin"), &binary)?;
        fs::create_dir(p("adir"))?;

        Ok(Self {
            dir,
            sample_a: p("a.txt"),
            sample_b: p("b.txt"),
            blank: p("blank.txt"),
            tabs: p("tabs.txt"),
            mixed: p("mixed.txt"),
            stdin_data,
            stdin_mix,
            dash_name: p("-dash.txt"),
            option_like: p("-n"),
            dash_v_file: p("-vfile.txt"),
            empty: p("empty.txt"),
            no_newline: p("no_newline.txt"),
            large: p("large.txt"),
            huge: p("huge.txt"),
            control: p("control.txt"),
            binary: p("binary.bin"),
            dir_path: p("adir"),
        })
    }
}

// --------------------- Test runner ----------------------------------------
fn run_tests(filter: Option<String>) -> Result<()> {
    let harness = Harness::new()?;
    let mut cases: Vec<TestCase> = vec![
        (
            "single file",
            Box::new(|h| h.compare_with_cat(&[h.fixtures.sample_a.to_str().unwrap()], None)),
        ),
        (
            "multiple files",
            Box::new(|h| {
                h.compare_with_cat(
                    &[
                        h.fixtures.sample_a.to_str().unwrap(),
                        h.fixtures.sample_b.to_str().unwrap(),
                        h.fixtures.blank.to_str().unwrap(),
                    ],
                    None,
                )
            }),
        ),
        (
            "stdin only",
            Box::new(|h| h.compare_with_cat(&["-"], Some(&h.fixtures.stdin_data))),
        ),
        (
            "dash operand",
            Box::new(|h| {
                h.compare_with_cat(
                    &[
                        h.fixtures.sample_a.to_str().unwrap(),
                        "-",
                        h.fixtures.sample_b.to_str().unwrap(),
                    ],
                    Some(&h.fixtures.stdin_mix),
                )
            }),
        ),
        (
            "dash filename",
            Box::new(|h| h.compare_with_cat(&["--", h.fixtures.dash_name.to_str().unwrap()], None)),
        ),
        (
            "-n option",
            Box::new(|h| h.compare_with_cat(&["-n", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "-n across files",
            Box::new(|h| {
                h.compare_with_cat(
                    &[
                        "-n",
                        h.fixtures.sample_a.to_str().unwrap(),
                        h.fixtures.blank.to_str().unwrap(),
                    ],
                    None,
                )
            }),
        ),
        (
            "-E option",
            Box::new(|h| h.compare_with_cat(&["-E", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "-T option (file)",
            Box::new(|h| h.compare_with_cat(&["-T", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "-T option (stdin)",
            Box::new(|h| h.compare_with_cat(&["-T", "-"], Some(&fs::read(&h.fixtures.tabs)?))),
        ),
        (
            "-E option large",
            Box::new(|h| h.compare_with_cat(&["-E", h.fixtures.large.to_str().unwrap()], None)),
        ),
        (
            "-E option huge",
            Box::new(|h| h.compare_with_cat(&["-E", h.fixtures.huge.to_str().unwrap()], None)),
        ),
        ("-T fifo fast path", Box::new(test_fifo_tabs)),
        (
            "-nET combo",
            Box::new(|h| h.compare_with_cat(&["-nET", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "-EnT combo order",
            Box::new(|h| h.compare_with_cat(&["-EnT", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "stdin numbered",
            Box::new(|h| h.compare_with_cat(&["-n", "-"], Some(&h.fixtures.stdin_data))),
        ),
        (
            "empty file",
            Box::new(|h| h.compare_with_cat(&[h.fixtures.empty.to_str().unwrap()], None)),
        ),
        (
            "no newline + -E",
            Box::new(|h| {
                h.compare_with_cat(&["-E", h.fixtures.no_newline.to_str().unwrap()], None)
            }),
        ),
        (
            "large file streaming",
            Box::new(|h| h.compare_with_cat(&[h.fixtures.large.to_str().unwrap()], None)),
        ),
        (
            "-n large file",
            Box::new(|h| h.compare_with_cat(&["-n", h.fixtures.large.to_str().unwrap()], None)),
        ),
        (
            "dash filename with numbering",
            Box::new(|h| {
                h.compare_with_cat(&["-n", "--", h.fixtures.dash_name.to_str().unwrap()], None)
            }),
        ),
        (
            "bundle -nb",
            Box::new(|h| h.compare_with_cat(&["-nb", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "bundle -bn",
            Box::new(|h| h.compare_with_cat(&["-bn", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "bundle -ns",
            Box::new(|h| h.compare_with_cat(&["-ns", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "bundle -sn",
            Box::new(|h| h.compare_with_cat(&["-sn", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "-n empty file",
            Box::new(|h| h.compare_with_cat(&["-n", h.fixtures.empty.to_str().unwrap()], None)),
        ),
        (
            "-b empty file",
            Box::new(|h| h.compare_with_cat(&["-b", h.fixtures.empty.to_str().unwrap()], None)),
        ),
        (
            "-s empty file",
            Box::new(|h| h.compare_with_cat(&["-s", h.fixtures.empty.to_str().unwrap()], None)),
        ),
        (
            "-v with tabs file",
            Box::new(|h| h.compare_with_cat(&["-v", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "-T with no tabs",
            Box::new(|h| h.compare_with_cat(&["-T", h.fixtures.sample_a.to_str().unwrap()], None)),
        ),
        (
            "-E with tabs file",
            Box::new(|h| h.compare_with_cat(&["-E", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "-A with tabs file",
            Box::new(|h| h.compare_with_cat(&["-A", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "-e with no newline",
            Box::new(|h| {
                h.compare_with_cat(&["-e", h.fixtures.no_newline.to_str().unwrap()], None)
            }),
        ),
        (
            "-t with tabs via stdin",
            Box::new(|h| h.compare_with_cat(&["-t", "-"], Some(&fs::read(&h.fixtures.tabs)?))),
        ),
        (
            "-b option",
            Box::new(|h| h.compare_with_cat(&["-b", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "-s option",
            Box::new(|h| h.compare_with_cat(&["-s", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "-v option",
            Box::new(|h| h.compare_with_cat(&["-v", h.fixtures.control.to_str().unwrap()], None)),
        ),
        (
            "-A shortcut",
            Box::new(|h| h.compare_with_cat(&["-A", h.fixtures.control.to_str().unwrap()], None)),
        ),
        (
            "-e shortcut",
            Box::new(|h| h.compare_with_cat(&["-e", h.fixtures.control.to_str().unwrap()], None)),
        ),
        (
            "-t shortcut",
            Box::new(|h| h.compare_with_cat(&["-t", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "-u option",
            Box::new(|h| h.compare_with_cat(&["-u", h.fixtures.sample_a.to_str().unwrap()], None)),
        ),
        (
            "bundled options -bnEs",
            Box::new(|h| h.compare_with_cat(&["-bnEs", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "option-like operand after file",
            Box::new(|h| {
                h.compare_with_cat(
                    &[
                        h.fixtures.sample_a.to_str().unwrap(),
                        h.fixtures.option_like.to_str().unwrap(),
                    ],
                    None,
                )
            }),
        ),
        (
            "-- stops option parsing",
            Box::new(|h| {
                h.compare_with_cat(&["--", h.fixtures.dash_v_file.to_str().unwrap()], None)
            }),
        ),
        (
            "-- mid-argv parsing",
            Box::new(test_mid_argv_double_dash),
        ),
        (
            "stdin then option-like operand",
            Box::new(test_stdin_then_option_operand),
        ),
        (
            "multiple -- markers",
            Box::new(test_multiple_double_dash),
        ),
        (
            "redundant -n flags",
            Box::new(|h| {
                h.compare_with_cat(&["-n", "-n", h.fixtures.sample_a.to_str().unwrap()], None)
            }),
        ),
        (
            "options after operand parsed",
            Box::new(|h| {
                h.compare_with_cat(&[h.fixtures.sample_a.to_str().unwrap(), "-n"], None)
            }),
        ),
        (
            "long option after operand",
            Box::new(|h| {
                h.compare_with_cat(&[h.fixtures.sample_a.to_str().unwrap(), "--number"], None)
            }),
        ),
        (
            "long option stdin",
            Box::new(|h| h.compare_with_cat(&["--number", "-"], Some(&h.fixtures.stdin_data))),
        ),
        ("long options", Box::new(test_long_options)),
        ("option permutation mixed", Box::new(test_option_permutation_mixed)),
        ("option permutation stdin", Box::new(test_option_permutation_stdin)),
        ("double dash no operands", Box::new(test_double_dash_no_operands)),
        ("invalid long option", Box::new(test_invalid_long_option)),
        ("invalid long option equals", Box::new(test_invalid_long_option_equals)),
        ("unknown long option equals", Box::new(test_unknown_long_option_equals)),
        ("long option disallow arg", Box::new(test_long_option_disallow_arg)),
        (
            "huge file numbering",
            Box::new(|h| h.compare_with_cat(&["-n", h.fixtures.huge.to_str().unwrap()], None)),
        ),
        (
            "binary passthrough",
            Box::new(|h| h.compare_with_cat(&[h.fixtures.binary.to_str().unwrap()], None)),
        ),
        ("plain stdout fifo fast path", Box::new(test_fifo_plain)),
        ("-n fifo fast path", Box::new(test_fifo_numbered)),
        ("-v fifo fast path", Box::new(test_fifo_visible)),
        ("fifo streaming", Box::new(test_fifo_stream)),
        ("--help switch", Box::new(test_help_output)),
        ("--version switch", Box::new(test_version_output)),
        ("--help stdout closed", Box::new(test_help_stdout_closed)),
        ("ENOENT vs EACCES messaging", Box::new(test_enoent_vs_eacces)),
        ("directory operand error", Box::new(test_directory_operand)),
        ("very long path ENAMETOOLONG", Box::new(test_enametoolong)),
        ("missing file error", Box::new(test_missing_file)),
        ("missing among files", Box::new(test_missing_among_files)),
        ("bad option error", Box::new(test_bad_option)),
        // Extra coverage beyond original shell suite
        (
            "-bs combo",
            Box::new(|h| {
                h.compare_with_cat(&["-b", "-s", h.fixtures.blank.to_str().unwrap()], None)
            }),
        ),
        (
            "-- then -n filename",
            Box::new(|h| h.compare_with_cat(&["--", h.fixtures.option_like.to_str().unwrap()], None)),
        ),
        (
            "-nT combo",
            Box::new(|h| h.compare_with_cat(&["-nT", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "stdin huge numbering",
            Box::new(|h| h.compare_with_cat(&["-n", "-"], Some(&fs::read(&h.fixtures.huge)?))),
        ),
        (
            "stdin empty",
            Box::new(|h| h.compare_with_cat(&["-"], Some(&[]))),
        ),
        (
            "dash file before options",
            Box::new(test_dash_file_before_options),
        ),
        (
            "literal dash filename",
            Box::new(test_literal_dash_filename),
        ),
        (
            "double stdin operands",
            Box::new(test_double_stdin_operands),
        ),
        (
            "stdin via -- then file",
            Box::new(test_double_dash_then_stdin_and_file),
        ),
        (
            "broken pipe write error",
            Box::new(test_broken_pipe_write_error),
        ),
        (
            "fifo decorated -vE",
            Box::new(test_fifo_decorated),
        ),
        (
            "binary passthrough pipe",
            Box::new(test_binary_passthrough),
        ),
        (
            "mixed stdin and file numbering",
            Box::new(test_mixed_stdin_file_numbering),
        ),
        (
            "no newline + -n",
            Box::new(|h| {
                h.compare_with_cat(&["-n", h.fixtures.no_newline.to_str().unwrap()], None)
            }),
        ),
        (
            "no newline + -b",
            Box::new(|h| {
                h.compare_with_cat(&["-b", h.fixtures.no_newline.to_str().unwrap()], None)
            }),
        ),
        (
            "-s with no blanks",
            Box::new(|h| h.compare_with_cat(&["-s", h.fixtures.sample_a.to_str().unwrap()], None)),
        ),
        (
            "combo -ns across files",
            Box::new(|h| {
                h.compare_with_cat(
                    &[
                        "-ns",
                        h.fixtures.sample_a.to_str().unwrap(),
                        h.fixtures.blank.to_str().unwrap(),
                    ],
                    None,
                )
            }),
        ),
        (
            "binary with -v",
            Box::new(|h| h.compare_with_cat(&["-v", h.fixtures.binary.to_str().unwrap()], None)),
        ),
        (
            "binary with -A",
            Box::new(|h| h.compare_with_cat(&["-A", h.fixtures.binary.to_str().unwrap()], None)),
        ),
        ("visible DEL", Box::new(test_visible_del)),
        ("line state across files", Box::new(test_line_state_across_files)),
        ("squeeze across files", Box::new(test_squeeze_across_files)),
        ("number nonblank across files", Box::new(test_b_across_files)),
        ("squeeze + no newline boundary", Box::new(test_squeeze_no_newline_boundary)),
        ("large line numbers", Box::new(test_large_line_numbers)),
        (
            "combo -nE",
            Box::new(|h| h.compare_with_cat(&["-nE", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "combo -bE",
            Box::new(|h| h.compare_with_cat(&["-bE", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "combo -bT",
            Box::new(|h| h.compare_with_cat(&["-bT", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "combo -sE",
            Box::new(|h| h.compare_with_cat(&["-sE", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "combo -sT",
            Box::new(|h| h.compare_with_cat(&["-sT", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "combo -A -s",
            Box::new(|h| h.compare_with_cat(&["-As", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "combo -e -s",
            Box::new(|h| h.compare_with_cat(&["-es", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "combo -t -s",
            Box::new(|h| h.compare_with_cat(&["-ts", h.fixtures.blank.to_str().unwrap()], None)),
        ),
        (
            "order -b then -n",
            Box::new(|h| {
                h.compare_with_cat(&["-b", "-n", h.fixtures.blank.to_str().unwrap()], None)
            }),
        ),
        (
            "order -n then -b",
            Box::new(|h| {
                h.compare_with_cat(&["-n", "-b", h.fixtures.blank.to_str().unwrap()], None)
            }),
        ),
        (
            "order --number then --number-nonblank",
            Box::new(|h| {
                h.compare_with_cat(
                    &["--number", "--number-nonblank", h.fixtures.blank.to_str().unwrap()],
                    None,
                )
            }),
        ),
        (
            "order --number-nonblank then --number",
            Box::new(|h| {
                h.compare_with_cat(
                    &["--number-nonblank", "--number", h.fixtures.blank.to_str().unwrap()],
                    None,
                )
            }),
        ),
        (
            "order -s then -n",
            Box::new(|h| {
                h.compare_with_cat(&["-s", "-n", h.fixtures.blank.to_str().unwrap()], None)
            }),
        ),
        (
            "order -n then -s",
            Box::new(|h| {
                h.compare_with_cat(&["-n", "-s", h.fixtures.blank.to_str().unwrap()], None)
            }),
        ),
        (
            "order -E then -T",
            Box::new(|h| h.compare_with_cat(&["-E", "-T", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "order -T then -E",
            Box::new(|h| h.compare_with_cat(&["-T", "-E", h.fixtures.tabs.to_str().unwrap()], None)),
        ),
        (
            "combo -nsvE",
            Box::new(|h| h.compare_with_cat(&["-nsvE", h.fixtures.control.to_str().unwrap()], None)),
        ),
        (
            "combo -bsvE",
            Box::new(|h| h.compare_with_cat(&["-bsvE", h.fixtures.control.to_str().unwrap()], None)),
        ),
        ("file named --help with --", Box::new(test_file_named_help)),
        ("file named --version with --", Box::new(test_file_named_version)),
        ("double dash then dash", Box::new(test_double_dash_then_dash)),
        ("stdin with option between dashes", Box::new(test_option_between_dashes)),
        ("space in filename", Box::new(test_space_in_filename)),
        (
            "multiple stdin operands with options",
            Box::new(test_multiple_stdin_operands_with_options),
        ),
        ("ENOTDIR path", Box::new(test_enotdir_path)),
        ("ELOOP symlink", Box::new(test_eloop_symlink)),
        ("directory operand with -n", Box::new(test_directory_operand_numbered)),
        ("directory operand with -v", Box::new(test_directory_operand_visible)),
        ("missing file with -n", Box::new(test_missing_file_numbered)),
        (
            "missing file with -v among files",
            Box::new(test_missing_file_visible_among_files),
        ),
        ("visible CR", Box::new(test_visible_cr)),
        ("visible NUL", Box::new(test_visible_nul)),
        ("visible 0xFF", Box::new(test_visible_ff)),
        ("tabs without newline -T", Box::new(test_tabs_no_newline_t)),
        ("tabs without newline -A", Box::new(test_tabs_no_newline_a)),
        ("long line no newline -n", Box::new(test_long_line_no_newline_number)),
        ("only newlines file -s", Box::new(test_only_newlines_file_s)),
        ("stdin only newlines -s", Box::new(test_stdin_only_newlines_s)),
        ("stdin empty with -n", Box::new(test_stdin_empty_numbered)),
        ("binary with -T", Box::new(test_binary_show_tabs)),
        ("binary with -E", Box::new(test_binary_show_ends)),
        ("fifo squeeze blank", Box::new(test_fifo_squeeze_blank)),
        ("fifo show ends", Box::new(test_fifo_show_ends)),
        ("fifo numbered show ends", Box::new(test_fifo_number_show_ends)),
        ("--show-ends stdin", Box::new(|h| {
            h.compare_with_cat(&["--show-ends", "-"], Some(&h.fixtures.stdin_data))
        })),
        ("--show-tabs stdin", Box::new(|h| {
            h.compare_with_cat(&["--show-tabs", "-"], Some(&fs::read(&h.fixtures.tabs)?))
        })),
        ("--show-nonprinting stdin", Box::new(|h| {
            h.compare_with_cat(&["--show-nonprinting", "-"], Some(&fs::read(&h.fixtures.control)?))
        })),
        ("--show-all stdin", Box::new(|h| {
            h.compare_with_cat(&["--show-all", "-"], Some(&fs::read(&h.fixtures.control)?))
        })),
        ("--number-nonblank stdin", Box::new(|h| {
            h.compare_with_cat(&["--number-nonblank", "-"], Some(&fs::read(&h.fixtures.blank)?))
        })),
        ("--squeeze-blank stdin", Box::new(|h| {
            h.compare_with_cat(&["--squeeze-blank", "-"], Some(&fs::read(&h.fixtures.blank)?))
        })),
        ("repeat -n", Box::new(|h| {
            h.compare_with_cat(&["-nn", h.fixtures.blank.to_str().unwrap()], None)
        })),
        ("--number --show-ends", Box::new(|h| {
            h.compare_with_cat(
                &["--number", "--show-ends", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("--number --show-tabs", Box::new(|h| {
            h.compare_with_cat(
                &["--number", "--show-tabs", h.fixtures.tabs.to_str().unwrap()],
                None,
            )
        })),
        ("--number --show-nonprinting", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--number",
                    "--show-nonprinting",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--number --show-all", Box::new(|h| {
            h.compare_with_cat(
                &["--number", "--show-all", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("--number-nonblank --show-ends", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--number-nonblank",
                    "--show-ends",
                    h.fixtures.blank.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--number-nonblank --show-tabs", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--number-nonblank",
                    "--show-tabs",
                    h.fixtures.tabs.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--number-nonblank --show-nonprinting", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--number-nonblank",
                    "--show-nonprinting",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--number-nonblank --show-all", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--number-nonblank",
                    "--show-all",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--squeeze-blank --number", Box::new(|h| {
            h.compare_with_cat(
                &["--squeeze-blank", "--number", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("--squeeze-blank --number-nonblank", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--squeeze-blank",
                    "--number-nonblank",
                    h.fixtures.blank.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--squeeze-blank --show-ends", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--squeeze-blank",
                    "--show-ends",
                    h.fixtures.blank.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--squeeze-blank --show-tabs", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--squeeze-blank",
                    "--show-tabs",
                    h.fixtures.tabs.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--squeeze-blank --show-nonprinting", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--squeeze-blank",
                    "--show-nonprinting",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--squeeze-blank --show-all", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--squeeze-blank",
                    "--show-all",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("stdin + file --number", Box::new(|h| {
            h.compare_with_cat(
                &["--number", "-", h.fixtures.sample_a.to_str().unwrap()],
                Some(&h.fixtures.stdin_data),
            )
        })),
        ("stdin + file --number-nonblank", Box::new(|h| {
            h.compare_with_cat(
                &["--number-nonblank", "-", h.fixtures.sample_a.to_str().unwrap()],
                Some(&fs::read(&h.fixtures.blank)?),
            )
        })),
        ("stdin + file --show-ends", Box::new(|h| {
            h.compare_with_cat(
                &["--show-ends", "-", h.fixtures.sample_a.to_str().unwrap()],
                Some(&h.fixtures.stdin_data),
            )
        })),
        ("stdin + file --show-tabs", Box::new(|h| {
            h.compare_with_cat(
                &["--show-tabs", "-", h.fixtures.sample_a.to_str().unwrap()],
                Some(&fs::read(&h.fixtures.tabs)?),
            )
        })),
        ("stdin + file --show-nonprinting", Box::new(|h| {
            h.compare_with_cat(
                &["--show-nonprinting", "-", h.fixtures.sample_a.to_str().unwrap()],
                Some(&fs::read(&h.fixtures.control)?),
            )
        })),
        ("stdin + file --show-all", Box::new(|h| {
            h.compare_with_cat(
                &["--show-all", "-", h.fixtures.sample_a.to_str().unwrap()],
                Some(&fs::read(&h.fixtures.control)?),
            )
        })),
        ("number across empty then data", Box::new(|h| {
            let empty = h.fixtures.dir.path().join("empty_then_data.txt");
            fs::write(&empty, b"")?;
            h.compare_with_cat(
                &["-n", empty.to_str().unwrap(), h.fixtures.sample_a.to_str().unwrap()],
                None,
            )
        })),
        ("number-nonblank across empty then data", Box::new(|h| {
            let empty = h.fixtures.dir.path().join("empty_then_data_b.txt");
            fs::write(&empty, b"")?;
            h.compare_with_cat(
                &["-b", empty.to_str().unwrap(), h.fixtures.sample_a.to_str().unwrap()],
                None,
            )
        })),
        ("squeeze across empty then blank", Box::new(|h| {
            let empty = h.fixtures.dir.path().join("empty_then_blank.txt");
            fs::write(&empty, b"")?;
            h.compare_with_cat(
                &["-s", empty.to_str().unwrap(), h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("show-ends across no-newline then file", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "-E",
                    h.fixtures.no_newline.to_str().unwrap(),
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("number across no-newline then file", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "-n",
                    h.fixtures.no_newline.to_str().unwrap(),
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("number-nonblank across no-newline then file", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "-b",
                    h.fixtures.no_newline.to_str().unwrap(),
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("symlink to file", Box::new(test_symlink_to_file)),
        ("symlink to directory", Box::new(test_symlink_to_dir)),
        ("hardlink to file", Box::new(test_hardlink_to_file)),
        ("dev null operand", Box::new(|h| h.compare_with_cat(&["/dev/null"], None))),
        ("fifo number nonblank", Box::new(test_fifo_number_nonblank)),
        ("file named --show-ends with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--show-ends");
            fs::write(&path, b"show ends file\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("crlf file -E", Box::new(|h| {
            let path = h.fixtures.dir.path().join("crlf_e.txt");
            fs::write(&path, b"one\\r\\ntwo\\r\\n")?;
            h.compare_with_cat(&["-E", path.to_str().unwrap()], None)
        })),
        ("crlf file -v", Box::new(|h| {
            let path = h.fixtures.dir.path().join("crlf_v.txt");
            fs::write(&path, b"one\\r\\ntwo\\r\\n")?;
            h.compare_with_cat(&["-v", path.to_str().unwrap()], None)
        })),
        ("tabs + control -A", Box::new(|h| {
            let path = h.fixtures.dir.path().join("tabs_control.txt");
            fs::write(&path, b"tab\\t\\x01\\n")?;
            h.compare_with_cat(&["-A", path.to_str().unwrap()], None)
        })),
        ("utf8 bytes -v", Box::new(|h| {
            let path = h.fixtures.dir.path().join("utf8_v.txt");
            fs::write(&path, [0xc3, 0xa9, b'\n'])?;
            h.compare_with_cat(&["-v", path.to_str().unwrap()], None)
        })),
        ("nul file -A", Box::new(|h| {
            let path = h.fixtures.dir.path().join("nul_a.txt");
            fs::write(&path, b"nul\\0end\\n")?;
            h.compare_with_cat(&["-A", path.to_str().unwrap()], None)
        })),
        ("redundant --number -n", Box::new(|h| {
            h.compare_with_cat(
                &["--number", "-n", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("redundant --number-nonblank -b", Box::new(|h| {
            h.compare_with_cat(
                &["--number-nonblank", "-b", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("redundant --squeeze-blank -s", Box::new(|h| {
            h.compare_with_cat(
                &["--squeeze-blank", "-s", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("redundant --show-ends -E", Box::new(|h| {
            h.compare_with_cat(
                &["--show-ends", "-E", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("redundant --show-tabs -T", Box::new(|h| {
            h.compare_with_cat(
                &["--show-tabs", "-T", h.fixtures.tabs.to_str().unwrap()],
                None,
            )
        })),
        ("redundant --show-nonprinting -v", Box::new(|h| {
            h.compare_with_cat(
                &["--show-nonprinting", "-v", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("redundant --show-all -A", Box::new(|h| {
            h.compare_with_cat(
                &["--show-all", "-A", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("combo -e -t", Box::new(|h| {
            h.compare_with_cat(&["-e", "-t", h.fixtures.tabs.to_str().unwrap()], None)
        })),
        ("combo -t -e", Box::new(|h| {
            h.compare_with_cat(&["-t", "-e", h.fixtures.tabs.to_str().unwrap()], None)
        })),
        ("combo -e -n", Box::new(|h| {
            h.compare_with_cat(&["-e", "-n", h.fixtures.blank.to_str().unwrap()], None)
        })),
        ("combo -t -n", Box::new(|h| {
            h.compare_with_cat(&["-t", "-n", h.fixtures.tabs.to_str().unwrap()], None)
        })),
        ("combo -e -b", Box::new(|h| {
            h.compare_with_cat(&["-e", "-b", h.fixtures.blank.to_str().unwrap()], None)
        })),
        ("combo -t -b", Box::new(|h| {
            h.compare_with_cat(&["-t", "-b", h.fixtures.tabs.to_str().unwrap()], None)
        })),
        ("combo -u -n", Box::new(|h| {
            h.compare_with_cat(&["-u", "-n", h.fixtures.blank.to_str().unwrap()], None)
        })),
        ("combo -u -b", Box::new(|h| {
            h.compare_with_cat(&["-u", "-b", h.fixtures.blank.to_str().unwrap()], None)
        })),
        ("combo -u -s", Box::new(|h| {
            h.compare_with_cat(&["-u", "-s", h.fixtures.blank.to_str().unwrap()], None)
        })),
        ("combo -u -v", Box::new(|h| {
            h.compare_with_cat(&["-u", "-v", h.fixtures.control.to_str().unwrap()], None)
        })),
        ("combo -u --show-all", Box::new(|h| {
            h.compare_with_cat(
                &["-u", "--show-all", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("file stdin file --number", Box::new(|h| {
            let mut stdin_payload = Vec::new();
            stdin_payload.extend_from_slice(b"stdin line 1\\n");
            stdin_payload.extend_from_slice(b"stdin line 2\\n");
            h.compare_with_cat(
                &[
                    "--number",
                    h.fixtures.sample_a.to_str().unwrap(),
                    "-",
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                Some(&stdin_payload),
            )
        })),
        ("file stdin file --number-nonblank", Box::new(|h| {
            let mut stdin_payload = Vec::new();
            stdin_payload.extend_from_slice(b"\\nstdin\\n\\n");
            h.compare_with_cat(
                &[
                    "--number-nonblank",
                    h.fixtures.sample_a.to_str().unwrap(),
                    "-",
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                Some(&stdin_payload),
            )
        })),
        ("file stdin file --squeeze-blank", Box::new(|h| {
            let mut stdin_payload = Vec::new();
            stdin_payload.extend_from_slice(b"line1\\n\\n\\nline2\\n");
            h.compare_with_cat(
                &[
                    "--squeeze-blank",
                    h.fixtures.sample_a.to_str().unwrap(),
                    "-",
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                Some(&stdin_payload),
            )
        })),
        ("file stdin file --show-ends", Box::new(|h| {
            let stdin_payload = b"stdin\\n".to_vec();
            h.compare_with_cat(
                &[
                    "--show-ends",
                    h.fixtures.sample_a.to_str().unwrap(),
                    "-",
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                Some(&stdin_payload),
            )
        })),
        ("file stdin file --show-tabs", Box::new(|h| {
            let tabs = fs::read(&h.fixtures.tabs)?;
            h.compare_with_cat(
                &[
                    "--show-tabs",
                    h.fixtures.sample_a.to_str().unwrap(),
                    "-",
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                Some(&tabs),
            )
        })),
        ("file stdin file --show-all", Box::new(|h| {
            let control = fs::read(&h.fixtures.control)?;
            h.compare_with_cat(
                &[
                    "--show-all",
                    h.fixtures.sample_a.to_str().unwrap(),
                    "-",
                    h.fixtures.sample_b.to_str().unwrap(),
                ],
                Some(&control),
            )
        })),
        ("file named --number with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--number");
            fs::write(&path, b"number file\\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("file named --show-tabs with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--show-tabs");
            fs::write(&path, b"tabs file\\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("file named --squeeze-blank with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--squeeze-blank");
            fs::write(&path, b"squeeze file\\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("file named -e with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("-e");
            fs::write(&path, b"dash e file\\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("file named -- with -n", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--");
            fs::write(&path, b"double dash file\\n")?;
            h.compare_with_cat(&["-n", "--", path.to_str().unwrap()], None)
        })),
        ("file named --number with -n", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--number");
            fs::write(&path, b"number file\\n")?;
            h.compare_with_cat(&["-n", "--", path.to_str().unwrap()], None)
        })),
        ("stdin -A tabs", Box::new(|h| {
            let tabs = fs::read(&h.fixtures.tabs)?;
            h.compare_with_cat(&["-A", "-"], Some(&tabs))
        })),
        ("stdin -b blanks", Box::new(|h| {
            let blank = fs::read(&h.fixtures.blank)?;
            h.compare_with_cat(&["-b", "-"], Some(&blank))
        })),
        ("stdin -nE blanks", Box::new(|h| {
            let blank = fs::read(&h.fixtures.blank)?;
            h.compare_with_cat(&["-nE", "-"], Some(&blank))
        })),
        ("stdin -bE blanks", Box::new(|h| {
            let blank = fs::read(&h.fixtures.blank)?;
            h.compare_with_cat(&["-bE", "-"], Some(&blank))
        })),
        ("stdin -sE blanks", Box::new(|h| {
            let blank = fs::read(&h.fixtures.blank)?;
            h.compare_with_cat(&["-sE", "-"], Some(&blank))
        })),
        ("stdin -v binary", Box::new(|h| {
            let binary = fs::read(&h.fixtures.binary)?;
            h.compare_with_cat(&["-v", "-"], Some(&binary))
        })),
        ("stdin --show-ends no newline", Box::new(|h| {
            let no_newline = fs::read(&h.fixtures.no_newline)?;
            h.compare_with_cat(&["--show-ends", "-"], Some(&no_newline))
        })),
        ("crlf file -A", Box::new(|h| {
            let path = h.fixtures.dir.path().join("crlf_a.txt");
            fs::write(&path, b"one\\r\\ntwo\\r\\n")?;
            h.compare_with_cat(&["-A", path.to_str().unwrap()], None)
        })),
        ("trailing spaces -E", Box::new(|h| {
            let path = h.fixtures.dir.path().join("trail_spaces.txt");
            fs::write(&path, b"space  \\t \\nnext line  \\n")?;
            h.compare_with_cat(&["-E", path.to_str().unwrap()], None)
        })),
        ("leading blanks -b", Box::new(|h| {
            let path = h.fixtures.dir.path().join("leading_blanks.txt");
            fs::write(&path, b"\\n\\nstart\\n\\nend\\n")?;
            h.compare_with_cat(&["-b", path.to_str().unwrap()], None)
        })),
        ("only tabs -T", Box::new(|h| {
            let path = h.fixtures.dir.path().join("only_tabs.txt");
            fs::write(&path, b"\\t\\t\\n\\tend\\n")?;
            h.compare_with_cat(&["-T", path.to_str().unwrap()], None)
        })),
        ("tabs + blanks -sT", Box::new(|h| {
            let path = h.fixtures.dir.path().join("tabs_blanks.txt");
            fs::write(&path, b"\\n\\n\\tcol\\n\\n\\n")?;
            h.compare_with_cat(&["-sT", path.to_str().unwrap()], None)
        })),
        ("squeeze across three files", Box::new(|h| {
            let a = h.fixtures.dir.path().join("squeeze_three_a.txt");
            let b = h.fixtures.dir.path().join("squeeze_three_b.txt");
            let c = h.fixtures.dir.path().join("squeeze_three_c.txt");
            fs::write(&a, b"line1\\n\\n")?;
            fs::write(&b, b"\\n\\nline2\\n")?;
            fs::write(&c, b"\\n\\nline3\\n")?;
            h.compare_with_cat(
                &[
                    "-s",
                    a.to_str().unwrap(),
                    b.to_str().unwrap(),
                    c.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("no newline + -A", Box::new(|h| {
            h.compare_with_cat(&["-A", h.fixtures.no_newline.to_str().unwrap()], None)
        })),
        ("visible formfeed", Box::new(|h| {
            let path = h.fixtures.dir.path().join("formfeed.txt");
            fs::write(&path, b"form\\x0cfeed\\n")?;
            h.compare_with_cat(&["-v", path.to_str().unwrap()], None)
        })),
        ("symlink chain", Box::new(test_symlink_chain)),
        ("relative symlink", Box::new(test_relative_symlink)),
        ("fifo show all", Box::new(test_fifo_show_all)),
        ("fifo show tabs and ends", Box::new(test_fifo_show_tabs_ends)),
        ("directory operand with -E", Box::new(|h| {
            h.compare_with_cat(&["-E", h.fixtures.dir_path.to_str().unwrap()], None)
        })),
        ("redundant --show-ends --show-ends", Box::new(|h| {
            h.compare_with_cat(
                &["--show-ends", "--show-ends", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        (
            "long combo --show-nonprinting --show-ends",
            Box::new(|h| {
                h.compare_with_cat(
                    &[
                        "--show-nonprinting",
                        "--show-ends",
                        h.fixtures.control.to_str().unwrap(),
                    ],
                    None,
                )
            }),
        ),
        (
            "long combo --show-nonprinting --show-tabs",
            Box::new(|h| {
                h.compare_with_cat(
                    &[
                        "--show-nonprinting",
                        "--show-tabs",
                        h.fixtures.control.to_str().unwrap(),
                    ],
                    None,
                )
            }),
        ),
        ("long combo --show-all --number", Box::new(|h| {
            h.compare_with_cat(
                &["--show-all", "--number", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("long combo --show-all --number-nonblank", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--show-all",
                    "--number-nonblank",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("long combo --show-tabs --number", Box::new(|h| {
            h.compare_with_cat(
                &["--show-tabs", "--number", h.fixtures.tabs.to_str().unwrap()],
                None,
            )
        })),
        ("combo -A -n", Box::new(|h| {
            h.compare_with_cat(&["-A", "-n", h.fixtures.control.to_str().unwrap()], None)
        })),
        ("combo -A -b", Box::new(|h| {
            h.compare_with_cat(&["-A", "-b", h.fixtures.control.to_str().unwrap()], None)
        })),
        ("stdin -A control", Box::new(|h| {
            let control = fs::read(&h.fixtures.control)?;
            h.compare_with_cat(&["-A", "-"], Some(&control))
        })),
        ("--show-ends with -n", Box::new(|h| {
            h.compare_with_cat(
                &["--show-ends", "-n", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("--show-tabs with -n", Box::new(|h| {
            h.compare_with_cat(
                &["--show-tabs", "-n", h.fixtures.tabs.to_str().unwrap()],
                None,
            )
        })),
        ("--show-nonprinting with -n", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--show-nonprinting",
                    "-n",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--show-all with -n", Box::new(|h| {
            h.compare_with_cat(
                &["--show-all", "-n", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("--show-ends with -b", Box::new(|h| {
            h.compare_with_cat(
                &["--show-ends", "-b", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("--show-tabs with -b", Box::new(|h| {
            h.compare_with_cat(
                &["--show-tabs", "-b", h.fixtures.tabs.to_str().unwrap()],
                None,
            )
        })),
        ("--show-nonprinting with -b", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "--show-nonprinting",
                    "-b",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("--show-all with -b", Box::new(|h| {
            h.compare_with_cat(
                &["--show-all", "-b", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("-s with --number", Box::new(|h| {
            h.compare_with_cat(
                &["-s", "--number", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("-s with --number-nonblank", Box::new(|h| {
            h.compare_with_cat(
                &["-s", "--number-nonblank", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("-s with --show-ends", Box::new(|h| {
            h.compare_with_cat(
                &["-s", "--show-ends", h.fixtures.blank.to_str().unwrap()],
                None,
            )
        })),
        ("-s with --show-tabs", Box::new(|h| {
            h.compare_with_cat(
                &["-s", "--show-tabs", h.fixtures.tabs.to_str().unwrap()],
                None,
            )
        })),
        ("-s with --show-nonprinting", Box::new(|h| {
            h.compare_with_cat(
                &[
                    "-s",
                    "--show-nonprinting",
                    h.fixtures.control.to_str().unwrap(),
                ],
                None,
            )
        })),
        ("-s with --show-all", Box::new(|h| {
            h.compare_with_cat(
                &["-s", "--show-all", h.fixtures.control.to_str().unwrap()],
                None,
            )
        })),
        ("double stdin --number", Box::new(|h| {
            h.compare_with_cat(&["--number", "-", "-"], Some(&h.fixtures.stdin_data))
        })),
        ("--show-nonprinting binary", Box::new(|h| {
            h.compare_with_cat(
                &["--show-nonprinting", h.fixtures.binary.to_str().unwrap()],
                None,
            )
        })),
        ("--show-all binary", Box::new(|h| {
            h.compare_with_cat(&["--show-all", h.fixtures.binary.to_str().unwrap()], None)
        })),
        ("--show-tabs with no tabs", Box::new(|h| {
            h.compare_with_cat(
                &["--show-tabs", h.fixtures.sample_a.to_str().unwrap()],
                None,
            )
        })),
        ("--show-ends no newline file", Box::new(|h| {
            h.compare_with_cat(
                &["--show-ends", h.fixtures.no_newline.to_str().unwrap()],
                None,
            )
        })),
        ("--number empty file", Box::new(|h| {
            h.compare_with_cat(&["--number", h.fixtures.empty.to_str().unwrap()], None)
        })),
        ("--number-nonblank empty file", Box::new(|h| {
            h.compare_with_cat(
                &["--number-nonblank", h.fixtures.empty.to_str().unwrap()],
                None,
            )
        })),
        ("--squeeze-blank empty file", Box::new(|h| {
            h.compare_with_cat(
                &["--squeeze-blank", h.fixtures.empty.to_str().unwrap()],
                None,
            )
        })),
        ("--show-all empty file", Box::new(|h| {
            h.compare_with_cat(&["--show-all", h.fixtures.empty.to_str().unwrap()], None)
        })),
        ("--show-nonprinting empty file", Box::new(|h| {
            h.compare_with_cat(
                &["--show-nonprinting", h.fixtures.empty.to_str().unwrap()],
                None,
            )
        })),
        ("only newlines file -b", Box::new(|h| {
            let path = h.fixtures.dir.path().join("only_newlines_b.txt");
            fs::write(&path, b"\n\n\n\n")?;
            h.compare_with_cat(&["-b", path.to_str().unwrap()], None)
        })),
        ("stdin only newlines -b", Box::new(|h| {
            h.compare_with_cat(&["-b", "-"], Some(b"\n\n\n"))
        })),
        ("only newlines file -n", Box::new(|h| {
            let path = h.fixtures.dir.path().join("only_newlines_n.txt");
            fs::write(&path, b"\n\n\n\n")?;
            h.compare_with_cat(&["-n", path.to_str().unwrap()], None)
        })),
        ("stdin only newlines -n", Box::new(|h| {
            h.compare_with_cat(&["-n", "-"], Some(b"\n\n\n"))
        })),
        ("stdin only newlines --number-nonblank", Box::new(|h| {
            h.compare_with_cat(&["--number-nonblank", "-"], Some(b"\n\n\n"))
        })),
        ("stdin only newlines --show-ends", Box::new(|h| {
            h.compare_with_cat(&["--show-ends", "-"], Some(b"\n\n\n"))
        })),
        ("file named -A with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("-A");
            fs::write(&path, b"dash A file\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("file named --show-all with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--show-all");
            fs::write(&path, b"show all file\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("file named --show-nonprinting with --", Box::new(|h| {
            let path = h.fixtures.dir.path().join("--show-nonprinting");
            fs::write(&path, b"show nonprinting file\n")?;
            h.compare_with_cat(&["--", path.to_str().unwrap()], None)
        })),
        ("bad option bundle", Box::new(test_bad_option_bundle)),
        (
            "process asm keeps comment-only lines",
            Box::new(test_comment_preservation),
        ),
    ];

    add_matrix_cases(&mut cases);

    let total = cases.len();
    let mut passed = 0usize;
    for (name, case) in cases.drain(..) {
        if let Some(f) = &filter {
            if !name.contains(f) {
                continue;
            }
        }
        if VERBOSE.load(Ordering::Relaxed) {
            println!("[RUN ] {name}");
        }
        match case(&harness) {
            Ok(_) => {
                passed += 1;
                println!("[PASS] {name}");
            }
            Err(e) => {
                println!("[FAIL] {name}: {e:#}");
            }
        }
    }
    println!(
        "\n{passed}/{total} tests executed{}.",
        if filter.is_some() { " (filtered)" } else { "" }
    );
    if passed == total || filter.is_some() {
        return Ok(());
    }
    bail!("failures encountered");
}

// --------------------- Matrix coverage -----------------------------------
#[derive(Clone, Copy)]
enum FixtureKey {
    SampleA,
    Blank,
    Tabs,
    Mixed,
    Control,
    NoNewline,
    Binary,
}

fn add_matrix_cases(cases: &mut Vec<TestCase>) {
    let mut specs: Vec<(String, Vec<String>)> = Vec::new();
    let mut seen = HashSet::<String>::new();

    let mut push_spec = |name: String, args: Vec<String>| {
        let key = args.join("\0");
        if seen.insert(key) {
            specs.push((name, args));
        }
    };

    push_spec("no options".to_string(), Vec::new());

    let short_flags = ['n', 'b', 's', 'E', 'T', 'v', 'u', 'A'];
    for mask in 1..(1u32 << short_flags.len()) {
        let mut flags = Vec::new();
        for (idx, flag) in short_flags.iter().enumerate() {
            if (mask >> idx) & 1 == 1 {
                flags.push(*flag);
            }
        }
        let bundle = format!("-{}", flags.iter().collect::<String>());
        push_spec(format!("short bundled {bundle}"), vec![bundle.clone()]);
        if flags.len() > 1 {
            let separate: Vec<String> = flags.iter().map(|f| format!("-{f}")).collect();
            push_spec(format!("short separate {}", separate.join(" ")), separate);
        }
    }

    let extra_short = vec![
        vec!["-e"],
        vec!["-t"],
        vec!["-e", "-s"],
        vec!["-t", "-s"],
        vec!["-e", "-n"],
        vec!["-t", "-n"],
        vec!["-e", "-b"],
        vec!["-t", "-b"],
        vec!["-e", "-u"],
        vec!["-t", "-u"],
        vec!["-e", "-s", "-n"],
        vec!["-t", "-s", "-n"],
        vec!["-e", "-s", "-b"],
        vec!["-t", "-s", "-b"],
    ];
    for opts in extra_short {
        push_spec(
            format!("short extra {}", opts.join(" ")),
            opts.into_iter().map(|s| s.to_string()).collect(),
        );
    }

    let long_flags = [
        "--number",
        "--number-nonblank",
        "--squeeze-blank",
        "--show-ends",
        "--show-tabs",
        "--show-nonprinting",
        "--show-all",
    ];
    for mask in 1..(1u32 << long_flags.len()) {
        let mut opts = Vec::new();
        for (idx, flag) in long_flags.iter().enumerate() {
            if (mask >> idx) & 1 == 1 {
                opts.push((*flag).to_string());
            }
        }
        push_spec(format!("long {}", opts.join(" ")), opts);
    }

    let order_sensitive = vec![
        vec!["-n", "-b"],
        vec!["-b", "-n"],
        vec!["-s", "-n"],
        vec!["-n", "-s"],
        vec!["-s", "-b"],
        vec!["-b", "-s"],
        vec!["-E", "-T"],
        vec!["-T", "-E"],
        vec!["--number", "--number-nonblank"],
        vec!["--number-nonblank", "--number"],
        vec!["--squeeze-blank", "--number"],
        vec!["--number", "--squeeze-blank"],
        vec!["--show-ends", "--show-tabs"],
        vec!["--show-tabs", "--show-ends"],
    ];
    for opts in order_sensitive {
        push_spec(
            format!("order {}", opts.join(" ")),
            opts.into_iter().map(|s| s.to_string()).collect(),
        );
    }

    for (label, opts) in specs {
        let opts_single = opts.clone();
        let name: &'static str = Box::leak(format!("matrix file {label}").into_boxed_str());
        cases.push((name, Box::new(move |h| {
            let args = build_args_with_file(h, &opts_single);
            let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            h.compare_with_cat(&args_ref, None)
        })));

        let opts_multi = opts.clone();
        let name: &'static str = Box::leak(format!("matrix multi {label}").into_boxed_str());
        cases.push((name, Box::new(move |h| {
            let args = build_args_with_multi(h, &opts_multi);
            let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            h.compare_with_cat(&args_ref, None)
        })));

        let opts_stdin = opts.clone();
        let name: &'static str = Box::leak(format!("matrix stdin {label}").into_boxed_str());
        cases.push((name, Box::new(move |h| {
            let input_key = pick_fixture_key(&opts_stdin);
            let input = fixture_bytes(h, input_key)?;
            let args = build_args_with_stdin(&opts_stdin);
            let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            h.compare_with_cat(&args_ref, Some(&input))
        })));

        let opts_stdin_file = opts.clone();
        let name: &'static str = Box::leak(format!("matrix stdin+file {label}").into_boxed_str());
        cases.push((name, Box::new(move |h| {
            let input_key = pick_fixture_key(&opts_stdin_file);
            let input = fixture_bytes(h, input_key)?;
            let args = build_args_with_stdin_file(h, &opts_stdin_file);
            let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            h.compare_with_cat(&args_ref, Some(&input))
        })));
    }

    let binary_opts = vec![
        vec![],
        vec!["-v"],
        vec!["-A"],
        vec!["-t"],
        vec!["-e"],
        vec!["--show-nonprinting"],
        vec!["--show-all"],
        vec!["--show-ends"],
        vec!["--show-tabs"],
    ];
    for opts in binary_opts {
        let label: &'static str =
            Box::leak(format!("matrix binary {}", opts.join(" ")).into_boxed_str());
        let opts = opts.into_iter().map(|s| s.to_string()).collect::<Vec<_>>();
        cases.push((label, Box::new(move |h| {
            let args = build_args_with_specific_file(h, &opts, FixtureKey::Binary);
            let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            h.compare_with_cat(&args_ref, None)
        })));
    }
}

fn build_args_with_file(h: &Harness, opts: &[String]) -> Vec<String> {
    let key = pick_fixture_key(opts);
    build_args_with_specific_file(h, opts, key)
}

fn build_args_with_specific_file(h: &Harness, opts: &[String], key: FixtureKey) -> Vec<String> {
    let mut args = opts.to_vec();
    let path = fixture_path(h, key);
    args.push(path.to_str().unwrap().to_string());
    args
}

fn build_args_with_multi(h: &Harness, opts: &[String]) -> Vec<String> {
    let key = pick_fixture_key(opts);
    let mut args = opts.to_vec();
    let first = fixture_path(h, key);
    args.push(first.to_str().unwrap().to_string());
    args.push(h.fixtures.sample_b.to_str().unwrap().to_string());
    args
}

fn build_args_with_stdin(opts: &[String]) -> Vec<String> {
    let mut args = opts.to_vec();
    args.push("-".to_string());
    args
}

fn build_args_with_stdin_file(h: &Harness, opts: &[String]) -> Vec<String> {
    let mut args = opts.to_vec();
    args.push("-".to_string());
    args.push(h.fixtures.sample_b.to_str().unwrap().to_string());
    args
}

fn fixture_path<'a>(h: &'a Harness, key: FixtureKey) -> &'a Path {
    match key {
        FixtureKey::SampleA => &h.fixtures.sample_a,
        FixtureKey::Blank => &h.fixtures.blank,
        FixtureKey::Tabs => &h.fixtures.tabs,
        FixtureKey::Mixed => &h.fixtures.mixed,
        FixtureKey::Control => &h.fixtures.control,
        FixtureKey::NoNewline => &h.fixtures.no_newline,
        FixtureKey::Binary => &h.fixtures.binary,
    }
}

fn fixture_bytes(h: &Harness, key: FixtureKey) -> Result<Vec<u8>> {
    Ok(fs::read(fixture_path(h, key))?)
}

fn pick_fixture_key(opts: &[String]) -> FixtureKey {
    if option_has_long(opts, "--show-all") || option_has_short(opts, 'A') || option_has_short(opts, 't')
    {
        return FixtureKey::Mixed;
    }
    if option_has_short(opts, 'T') || option_has_long(opts, "--show-tabs") {
        return FixtureKey::Tabs;
    }
    if option_has_short(opts, 'e')
        || option_has_short(opts, 'v')
        || option_has_long(opts, "--show-nonprinting")
    {
        return FixtureKey::Control;
    }
    if option_has_short(opts, 's')
        || option_has_short(opts, 'b')
        || option_has_short(opts, 'n')
        || option_has_long(opts, "--squeeze-blank")
        || option_has_long(opts, "--number-nonblank")
        || option_has_long(opts, "--number")
    {
        return FixtureKey::Blank;
    }
    if option_has_short(opts, 'E') || option_has_long(opts, "--show-ends") {
        return FixtureKey::NoNewline;
    }
    FixtureKey::SampleA
}

fn option_has_short(opts: &[String], flag: char) -> bool {
    opts.iter().any(|opt| {
        if !opt.starts_with('-') || opt.starts_with("--") {
            return false;
        }
        opt[1..].contains(flag)
    })
}

fn option_has_long(opts: &[String], flag: &str) -> bool {
    opts.iter().any(|opt| opt == flag)
}

// --------------------- Individual tests -----------------------------------
fn test_fifo_tabs(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("tabs_fast.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let tabs = fs::read(&h.fixtures.tabs)?;
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-T", fifo_path], &tabs, "-T fifo")
}

fn test_fifo_plain(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("plain_out.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = fs::read(&h.fixtures.large)?;
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &[fifo_path], &data, "fifo plain")
}

fn test_fifo_numbered(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("num_fast.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = fs::read(&h.fixtures.large)?;
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-n", fifo_path], &data, "-n fifo")
}

fn test_fifo_visible(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("vis_fast.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = fs::read(&h.fixtures.control)?;
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-v", fifo_path], &data, "-v fifo")
}

fn test_fifo_stream(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("stream.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let wcat = h.wcat.clone();
    let writer = std::thread::spawn({
        let fifo = fifo.clone();
        move || -> Result<()> {
            let mut f = File::create(&fifo)?;
            writeln!(f, "chunk1")?;
            std::thread::sleep(std::time::Duration::from_millis(50));
            writeln!(f, "chunk2")?;
            Ok(())
        }
    });
    let out = run_cmd_with_arg0(&wcat, &[fifo.to_str().unwrap()], None, Some(&h.cat))?;
    writer.join().unwrap()?;
    if out.stdout != b"chunk1\nchunk2\n" {
        bail!("fifo stream mismatch");
    }
    let fifo_path = fifo.to_str().unwrap();
    let wcat_file = NamedTempFile::new_in(h.fixtures.dir.path())?;
    let cat_file = NamedTempFile::new_in(h.fixtures.dir.path())?;
    let run_stream_to_file = |cmd: &Path, arg0_override: Option<&Path>, output: &Path| -> Result<()> {
        let writer = std::thread::spawn({
            let fifo = fifo.clone();
            move || -> Result<()> {
                let mut f = File::create(&fifo)?;
                writeln!(f, "chunk1")?;
                std::thread::sleep(std::time::Duration::from_millis(50));
                writeln!(f, "chunk2")?;
                Ok(())
            }
        });
        run_cmd_to_file(cmd, &[fifo_path], None, arg0_override, output)?;
        writer.join().unwrap()?;
        Ok(())
    };
    run_stream_to_file(&h.wcat, Some(&h.cat), wcat_file.path())?;
    run_stream_to_file(&h.cat, None, cat_file.path())?;
    let wcat_bytes = fs::read(wcat_file.path())?;
    let cat_bytes = fs::read(cat_file.path())?;
    if wcat_bytes != cat_bytes {
        bail!(
            "fifo stream file output mismatch (wcat {}B vs cat {}B)",
            wcat_bytes.len(),
            cat_bytes.len()
        );
    }
    Ok(())
}

fn test_help_output(h: &Harness) -> Result<()> {
    let out = run_cmd_with_arg0(&h.wcat, &["--help"], None, Some(&h.cat))?;
    let cat_out = run_cmd(&h.cat, &["--help"], None)?;
    if out.stdout == cat_out.stdout {
        bail!("help output should remain wcat-specific");
    }
    if !String::from_utf8_lossy(&out.stdout).contains("Usage: wcat") {
        bail!("help missing usage");
    }
    Ok(())
}

fn test_version_output(h: &Harness) -> Result<()> {
    let out = run_cmd_with_arg0(&h.wcat, &["--version"], None, Some(&h.cat))?;
    let cat_out = run_cmd(&h.cat, &["--version"], None)?;
    if out.stdout == cat_out.stdout {
        bail!("version output should remain wcat-specific");
    }
    if !String::from_utf8_lossy(&out.stdout).contains("wcat 0.1") {
        bail!("version string mismatch");
    }
    Ok(())
}

fn test_help_stdout_closed(h: &Harness) -> Result<()> {
    let wcat_status = Command::new(&h.wcat)
        .arg("--help")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    let cat_status = Command::new(&h.cat)
        .arg("--help")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if wcat_status.code() != cat_status.code() {
        bail!(
            "--help exit mismatch {:?} vs {:?}",
            wcat_status.code(),
            cat_status.code()
        );
    }
    Ok(())
}

fn test_missing_file(h: &Harness) -> Result<()> {
    let missing = h.fixtures.dir.path().join("missing.txt");
    h.compare_with_cat(&[missing.to_str().unwrap()], None)
}

fn test_missing_among_files(h: &Harness) -> Result<()> {
    let missing = h.fixtures.dir.path().join("missing.txt");
    let args = [
        h.fixtures.sample_a.to_str().unwrap(),
        missing.to_str().unwrap(),
        h.fixtures.sample_b.to_str().unwrap(),
    ];
    h.compare_with_cat(&args, None)
}

fn test_bad_option(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-x"], None)
}

fn test_bad_option_bundle(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-nZ"], None)
}

fn test_mid_argv_double_dash(h: &Harness) -> Result<()> {
    let args = ["-n", "--", "-n", h.fixtures.sample_a.to_str().unwrap()];
    h.compare_with_cat(&args, None)
}

fn test_stdin_then_option_operand(h: &Harness) -> Result<()> {
    let args = ["-", "-n"];
    h.compare_with_cat(&args, Some(&h.fixtures.stdin_data))
}

fn test_multiple_double_dash(h: &Harness) -> Result<()> {
    // Create a file literally named "--".
    let dashdash = h.fixtures.dir_path.join("--");
    fs::write(&dashdash, b"double dash file\n")?;
    let args = [
        "--",
        h.fixtures.sample_a.to_str().unwrap(),
        dashdash.to_str().unwrap(),
        h.fixtures.sample_b.to_str().unwrap(),
    ];
    h.compare_with_cat(&args, None)
}

fn test_long_options(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["--number", h.fixtures.blank.to_str().unwrap()], None)?;
    h.compare_with_cat(
        &["--number-nonblank", h.fixtures.blank.to_str().unwrap()],
        None,
    )?;
    h.compare_with_cat(
        &["--squeeze-blank", h.fixtures.blank.to_str().unwrap()],
        None,
    )?;
    h.compare_with_cat(&["--show-ends", h.fixtures.blank.to_str().unwrap()], None)?;
    h.compare_with_cat(&["--show-tabs", h.fixtures.tabs.to_str().unwrap()], None)?;
    h.compare_with_cat(
        &["--show-nonprinting", h.fixtures.control.to_str().unwrap()],
        None,
    )?;
    h.compare_with_cat(&["--show-all", h.fixtures.control.to_str().unwrap()], None)
}

fn test_option_permutation_mixed(h: &Harness) -> Result<()> {
    let args = [
        h.fixtures.sample_a.to_str().unwrap(),
        "-n",
        h.fixtures.sample_b.to_str().unwrap(),
        "--show-ends",
    ];
    h.compare_with_cat(&args, None)
}

fn test_option_permutation_stdin(h: &Harness) -> Result<()> {
    let args = [
        h.fixtures.sample_a.to_str().unwrap(),
        "-",
        "-n",
        h.fixtures.sample_b.to_str().unwrap(),
    ];
    let mut stdin_payload = Vec::new();
    stdin_payload.extend_from_slice(b"stdin line 1\n");
    stdin_payload.extend_from_slice(b"stdin line 2\n");
    h.compare_with_cat(&args, Some(&stdin_payload))
}

fn test_double_dash_no_operands(h: &Harness) -> Result<()> {
    let args = ["--"];
    h.compare_with_cat(&args, Some(&h.fixtures.stdin_data))
}

fn test_invalid_long_option(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["--nope"], None)
}

fn test_invalid_long_option_equals(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["--number=1"], None)
}

fn test_unknown_long_option_equals(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["--nope=1"], None)
}

fn test_long_option_disallow_arg(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["--help=1"], None)
}

fn test_line_state_across_files(h: &Harness) -> Result<()> {
    let no_nl = h.fixtures.dir.path().join("no_newline_boundary.txt");
    let with_nl = h.fixtures.dir.path().join("newline_boundary.txt");
    fs::write(&no_nl, b"first")?;
    fs::write(&with_nl, b"second\n")?;
    h.compare_with_cat(
        &["-n", no_nl.to_str().unwrap(), with_nl.to_str().unwrap()],
        None,
    )
}

fn test_squeeze_across_files(h: &Harness) -> Result<()> {
    let a = h.fixtures.dir.path().join("blank_a.txt");
    let b = h.fixtures.dir.path().join("blank_b.txt");
    fs::write(&a, b"line1\n\n")?;
    fs::write(&b, b"\n\nline2\n")?;
    h.compare_with_cat(&["-s", a.to_str().unwrap(), b.to_str().unwrap()], None)
}

fn test_b_across_files(h: &Harness) -> Result<()> {
    let a = h.fixtures.dir.path().join("b_across_a.txt");
    let b = h.fixtures.dir.path().join("b_across_b.txt");
    fs::write(&a, b"line1\n\n")?;
    fs::write(&b, b"\nline2\n")?;
    h.compare_with_cat(&["-b", a.to_str().unwrap(), b.to_str().unwrap()], None)
}

fn test_squeeze_no_newline_boundary(h: &Harness) -> Result<()> {
    let a = h.fixtures.dir.path().join("squeeze_no_nl_a.txt");
    let b = h.fixtures.dir.path().join("squeeze_no_nl_b.txt");
    fs::write(&a, b"line1\n\n")?;
    fs::write(&b, b"\nline2")?;
    h.compare_with_cat(&["-s", a.to_str().unwrap(), b.to_str().unwrap()], None)
}

fn test_large_line_numbers(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("million_lines.txt");
    let lines = 1_000_005usize;
    let mut data = Vec::with_capacity(lines * 2);
    for _ in 0..lines {
        data.extend_from_slice(b"x\n");
    }
    fs::write(&path, &data)?;
    h.compare_with_cat(&["-n", path.to_str().unwrap()], None)
}

fn test_enoent_vs_eacces(h: &Harness) -> Result<()> {
    let missing = h.fixtures.dir_path.join("nope");
    let locked = h.fixtures.dir_path.join("locked.txt");
    fs::write(&locked, b"locked")?;
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000))?;

    let result = (|| {
        h.compare_with_cat(&[missing.to_str().unwrap()], None)?;
        h.compare_with_cat(&[locked.to_str().unwrap()], None)
    })();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o600))?;
    result
}

fn test_directory_operand(h: &Harness) -> Result<()> {
    h.compare_with_cat(&[h.fixtures.dir_path.to_str().unwrap()], None)
}

fn test_enametoolong(h: &Harness) -> Result<()> {
    let long_name = "a".repeat(5000);
    let path = h.fixtures.dir_path.join(long_name);
    h.compare_with_cat(&[path.to_str().unwrap()], None)
}

fn test_fifo_decorated(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir_path.join("decorated.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::S_IRWXU)?;

    let data = b"line1\n\nline2\tend\n";
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-vE", fifo_path], data, "fifo decorated")
}

fn test_binary_passthrough(h: &Harness) -> Result<()> {
    let mut buf = vec![0u8; 2 * 1024 * 1024];
    rand::thread_rng().fill_bytes(&mut buf);
    h.compare_with_cat(&["-"], Some(&buf))
}

fn test_mixed_stdin_file_numbering(h: &Harness) -> Result<()> {
    let mut stdin_payload = Vec::new();
    stdin_payload.extend_from_slice(b"stdin first\n");
    stdin_payload.extend_from_slice(b"stdin second\n");
    h.compare_with_cat(
        &["-n", "-", h.fixtures.sample_a.to_str().unwrap(), "-"],
        Some(&stdin_payload),
    )
}

fn test_double_stdin_operands(h: &Harness) -> Result<()> {
    // Two "-" operands should read stdin once; second sees EOF.
    h.compare_with_cat(&["-", "-"], Some(&h.fixtures.stdin_data))
}

fn test_double_dash_then_stdin_and_file(h: &Harness) -> Result<()> {
    let args = ["--", "-", h.fixtures.sample_a.to_str().unwrap()];
    h.compare_with_cat(&args, Some(&h.fixtures.stdin_data))
}

fn test_broken_pipe_write_error(h: &Harness) -> Result<()> {
    // Pipe to head -n0 so stdout closes immediately; match cat's exit status/stderr.
    let data = b"broken pipe data\n";

    let wcat_status = pipeline_exit(&h.wcat, data)?;
    let cat_status = pipeline_exit(&h.cat, data)?;
    if wcat_status != cat_status {
        bail!("broken pipe exit mismatch {:?} vs {:?}", wcat_status, cat_status);
    }
    Ok(())
}

fn pipeline_exit(cmd: &Path, data: &[u8]) -> Result<Option<i32>> {
    let mut producer = Command::new(cmd)
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .with_context(|| format!("spawn producer {cmd:?}"))?;

    let mut consumer = Command::new("head")
        .arg("-n0")
        .stdin(producer.stdout.take().unwrap())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .context("spawn head")?;
    let head_status = consumer.wait()?;
    producer.stdin.take().unwrap().write_all(data)?;
    let prod_status = producer.wait()?;
    let _ = head_status;
    Ok(prod_status.code())
}

fn test_dash_file_before_options(h: &Harness) -> Result<()> {
    let args = ["--", h.fixtures.dash_name.to_str().unwrap(), "-n"];
    h.compare_with_cat(&args, None)
}

fn test_literal_dash_filename(h: &Harness) -> Result<()> {
    let dash_path = h.fixtures.dir.path().join("-");
    fs::write(&dash_path, b"dash literal\n")?;
    let args = ["--", dash_path.to_str().unwrap()];
    h.compare_with_cat(&args, None)
}

fn test_visible_del(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("del.txt");
    fs::write(&path, b"del:\x7f!\n")?;
    h.compare_with_cat(&["-v", path.to_str().unwrap()], None)
}

fn test_file_named_help(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("--help");
    fs::write(&path, b"help file\n")?;
    h.compare_with_cat(&["--", path.to_str().unwrap()], None)
}

fn test_file_named_version(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("--version");
    fs::write(&path, b"version file\n")?;
    h.compare_with_cat(&["--", path.to_str().unwrap()], None)
}

fn test_double_dash_then_dash(h: &Harness) -> Result<()> {
    let args = ["--", "-"];
    h.compare_with_cat(&args, Some(&h.fixtures.stdin_data))
}

fn test_option_between_dashes(h: &Harness) -> Result<()> {
    let args = ["-", "-n", "-"];
    let mut stdin_payload = Vec::new();
    stdin_payload.extend_from_slice(b"first\n");
    stdin_payload.extend_from_slice(b"second\n");
    h.compare_with_cat(&args, Some(&stdin_payload))
}

fn test_space_in_filename(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("space name.txt");
    fs::write(&path, b"space\n")?;
    h.compare_with_cat(&[path.to_str().unwrap()], None)
}

fn test_multiple_stdin_operands_with_options(h: &Harness) -> Result<()> {
    let args = ["-n", "-", "-", "-"];
    let mut stdin_payload = Vec::new();
    stdin_payload.extend_from_slice(b"a\n");
    stdin_payload.extend_from_slice(b"b\n");
    h.compare_with_cat(&args, Some(&stdin_payload))
}

fn test_enotdir_path(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("notdir");
    fs::write(&path, b"data")?;
    let child = path.join("child");
    h.compare_with_cat(&[child.to_str().unwrap()], None)
}

fn test_eloop_symlink(h: &Harness) -> Result<()> {
    let a = h.fixtures.dir.path().join("loop_a");
    let b = h.fixtures.dir.path().join("loop_b");
    symlink(&b, &a)?;
    symlink(&a, &b)?;
    h.compare_with_cat(&[a.to_str().unwrap()], None)
}

fn test_symlink_to_file(h: &Harness) -> Result<()> {
    let link = h.fixtures.dir.path().join("link_to_a.txt");
    symlink(&h.fixtures.sample_a, &link)?;
    h.compare_with_cat(&[link.to_str().unwrap()], None)
}

fn test_symlink_to_dir(h: &Harness) -> Result<()> {
    let link = h.fixtures.dir.path().join("link_to_dir");
    symlink(&h.fixtures.dir_path, &link)?;
    h.compare_with_cat(&[link.to_str().unwrap()], None)
}

fn test_hardlink_to_file(h: &Harness) -> Result<()> {
    let link = h.fixtures.dir.path().join("hardlink_b.txt");
    fs::hard_link(&h.fixtures.sample_b, &link)?;
    h.compare_with_cat(&[link.to_str().unwrap()], None)
}

fn test_symlink_chain(h: &Harness) -> Result<()> {
    let target = h.fixtures.dir.path().join("chain_target.txt");
    let link1 = h.fixtures.dir.path().join("chain_link1");
    let link2 = h.fixtures.dir.path().join("chain_link2");
    fs::write(&target, b"chain target\n")?;
    symlink(&target, &link1)?;
    symlink(&link1, &link2)?;
    h.compare_with_cat(&[link2.to_str().unwrap()], None)
}

fn test_relative_symlink(h: &Harness) -> Result<()> {
    let base = h.fixtures.dir.path();
    let rel_dir = base.join("rel_dir");
    fs::create_dir(&rel_dir)?;
    let target = rel_dir.join("rel_target.txt");
    fs::write(&target, b"relative\n")?;
    let link = base.join("rel_link.txt");
    symlink(Path::new("rel_dir/rel_target.txt"), &link)?;
    h.compare_with_cat(&[link.to_str().unwrap()], None)
}

fn test_directory_operand_numbered(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-n", h.fixtures.dir_path.to_str().unwrap()], None)
}

fn test_directory_operand_visible(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-v", h.fixtures.dir_path.to_str().unwrap()], None)
}

fn test_missing_file_numbered(h: &Harness) -> Result<()> {
    let missing = h.fixtures.dir.path().join("missing_numbered.txt");
    h.compare_with_cat(&["-n", missing.to_str().unwrap()], None)
}

fn test_missing_file_visible_among_files(h: &Harness) -> Result<()> {
    let missing = h.fixtures.dir.path().join("missing_visible.txt");
    let args = [
        "-v",
        h.fixtures.sample_a.to_str().unwrap(),
        missing.to_str().unwrap(),
        h.fixtures.sample_b.to_str().unwrap(),
    ];
    h.compare_with_cat(&args, None)
}

fn test_visible_cr(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("cr.txt");
    fs::write(&path, b"carriage\rreturn\n")?;
    h.compare_with_cat(&["-v", path.to_str().unwrap()], None)
}

fn test_visible_nul(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("nul.txt");
    fs::write(&path, b"nul:\0x\n")?;
    h.compare_with_cat(&["-v", path.to_str().unwrap()], None)
}

fn test_visible_ff(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("ff.txt");
    fs::write(&path, b"ff:\xff!\n")?;
    h.compare_with_cat(&["-v", path.to_str().unwrap()], None)
}

fn test_tabs_no_newline_t(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("tabs_no_nl.txt");
    fs::write(&path, b"a\tb")?;
    h.compare_with_cat(&["-T", path.to_str().unwrap()], None)
}

fn test_tabs_no_newline_a(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("tabs_no_nl_a.txt");
    fs::write(&path, b"a\tb")?;
    h.compare_with_cat(&["-A", path.to_str().unwrap()], None)
}

fn test_long_line_no_newline_number(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("long_line.txt");
    let data = vec![b'x'; 600_000];
    fs::write(&path, &data)?;
    h.compare_with_cat(&["-n", path.to_str().unwrap()], None)
}

fn test_only_newlines_file_s(h: &Harness) -> Result<()> {
    let path = h.fixtures.dir.path().join("only_newlines.txt");
    fs::write(&path, b"\n\n\n\n")?;
    h.compare_with_cat(&["-s", path.to_str().unwrap()], None)
}

fn test_stdin_only_newlines_s(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-s", "-"], Some(b"\n\n\n\n"))
}

fn test_stdin_empty_numbered(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-n", "-"], Some(&[]))
}

fn test_binary_show_tabs(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-T", h.fixtures.binary.to_str().unwrap()], None)
}

fn test_binary_show_ends(h: &Harness) -> Result<()> {
    h.compare_with_cat(&["-E", h.fixtures.binary.to_str().unwrap()], None)
}

fn test_fifo_squeeze_blank(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("squeeze.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = b"one\n\n\n\nthree\n";
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-s", fifo_path], data, "fifo squeeze")
}

fn test_fifo_show_ends(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("show_ends.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = b"one\n\n";
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-E", fifo_path], data, "fifo show ends")
}

fn test_fifo_number_show_ends(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("num_ends.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = b"one\n\n";
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-nE", fifo_path], data, "fifo numbered ends")
}

fn test_fifo_show_all(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("show_all.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = b"tab\t\x01\n";
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-A", fifo_path], data, "fifo show all")
}

fn test_fifo_show_tabs_ends(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("show_tabs_ends.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = b"one\tend\n\n";
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(
        h,
        &fifo,
        &["-ET", fifo_path],
        data,
        "fifo show tabs and ends",
    )
}

fn test_fifo_number_nonblank(h: &Harness) -> Result<()> {
    let fifo = h.fixtures.dir.path().join("num_nonblank.fifo");
    mkfifo(&fifo, nix::sys::stat::Mode::from_bits_truncate(0o644))?;
    let data = b"one\n\nthree\n";
    let fifo_path = fifo.to_str().unwrap();
    compare_fifo_outputs(h, &fifo, &["-b", fifo_path], data, "fifo number nonblank")
}

fn test_comment_preservation(_h: &Harness) -> Result<()> {
    let tmp = TempDir::new()?;
    let asm = tmp.path().join("sample.asm");
    fs::write(
        &asm,
        b";only comment\nmov rax, rbx ; trailing\n  ; indented comment\nlabel: nop\n",
    )?;
    let out_dir = tmp.path().join("out");
    process_one_asm(&asm, &out_dir.join("sample.asm"))?;
    let content = fs::read_to_string(out_dir.join("sample.asm"))?;
    let lines: Vec<&str> = content.lines().collect();
    if lines[0].trim_start() != ";only comment" {
        bail!("comment-only line removed");
    }
    if !lines[1].contains("mov rax, rbx") || lines[1].contains(";") {
        bail!("trailing comment not stripped correctly");
    }
    if lines[2].trim_start() != "; indented comment" {
        bail!("indented comment line lost");
    }
    Ok(())
}

// --------------------- Helpers --------------------------------------------
fn ensure_wcat_built(root: &Path, binary: &Path) -> Result<()> {
    let asm = root.join("wcat/wcat.asm");
    let obj = root.join("wcat/wcat.o");
    let rebuild = !binary.exists()
        || !obj.exists()
        || fs::metadata(&asm)?.modified()?
            > fs::metadata(binary)
                .ok()
                .and_then(|m| m.modified().ok())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
    if rebuild {
        println!("[build] assembling wcat");
        let mut nasm = Command::new("nasm");
        nasm.current_dir(root.join("wcat"))
            .args(["-f", "elf64", "wcat.asm", "-o", "wcat.o"]);
        run_status(nasm)?;
        let mut ld = Command::new("ld");
        ld.current_dir(root.join("wcat"))
            .args(["-o", "wcat", "wcat.o"]);
        run_status(ld)?;
    }
    Ok(())
}

#[derive(Clone)]
struct CmdOutput {
    status: std::process::ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn run_cmd(cmd: &Path, args: &[&str], stdin_data: Option<&[u8]>) -> Result<CmdOutput> {
    run_cmd_with_arg0(cmd, args, stdin_data, None)
}

fn run_cmd_with_arg0(
    cmd: &Path,
    args: &[&str],
    stdin_data: Option<&[u8]>,
    arg0_override: Option<&Path>,
) -> Result<CmdOutput> {
    let mut command = Command::new(cmd);
    if let Some(arg0) = arg0_override {
        command.arg0(arg0);
    }
    command.args(args);
    if stdin_data.is_some() {
        command.stdin(Stdio::piped());
    }
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .with_context(|| format!("spawning {cmd:?}"))?;
    let stdin_writer = if let Some(data) = stdin_data {
        let mut stdin = child.stdin.take().unwrap();
        let owned = data.to_vec();
        Some(std::thread::spawn(move || -> std::io::Result<()> {
            stdin.write_all(&owned)
        }))
    } else {
        None
    };
    let output = child.wait_with_output()?;
    if let Some(writer) = stdin_writer {
        writer.join().unwrap()?;
    }
    if VERBOSE.load(Ordering::Relaxed) {
        println!(
            "[CMD ] {:?} {:?} -> status {:?}, stdout {}B, stderr {}B",
            cmd,
            args,
            output.status.code(),
            output.stdout.len(),
            output.stderr.len()
        );
    }
    Ok(CmdOutput {
        status: output.status,
        stdout: output.stdout,
        stderr: output.stderr,
    })
}

fn run_cmd_to_file(
    cmd: &Path,
    args: &[&str],
    stdin_data: Option<&[u8]>,
    arg0_override: Option<&Path>,
    output_path: &Path,
) -> Result<std::process::ExitStatus> {
    let stdout_file = File::create(output_path)?;
    let mut command = Command::new(cmd);
    if let Some(arg0) = arg0_override {
        command.arg0(arg0);
    }
    command.args(args);
    if stdin_data.is_some() {
        command.stdin(Stdio::piped());
    }
    command.stdout(stdout_file).stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .with_context(|| format!("spawning {cmd:?}"))?;
    let stdin_writer = if let Some(data) = stdin_data {
        let mut stdin = child.stdin.take().unwrap();
        let owned = data.to_vec();
        Some(std::thread::spawn(move || -> std::io::Result<()> {
            stdin.write_all(&owned)
        }))
    } else {
        None
    };
    let output = child.wait_with_output()?;
    if let Some(writer) = stdin_writer {
        writer.join().unwrap()?;
    }
    if VERBOSE.load(Ordering::Relaxed) {
        println!(
            "[CMD ] {:?} {:?} -> status {:?}, file stdout at {:?}, stderr {}B",
            cmd,
            args,
            output.status.code(),
            output_path,
            output.stderr.len()
        );
    }
    Ok(output.status)
}

fn compare_outputs(actual: CmdOutput, expected: CmdOutput, label: &str) -> Result<()> {
    if actual.stdout != expected.stdout
        || actual.stderr != expected.stderr
        || actual.status.code() != expected.status.code()
    {
        bail!(
            "{label} mismatch\nstdout diff? {}\nstderr diff? {}\nstatus {:?} vs {:?}",
            actual.stdout != expected.stdout,
            actual.stderr != expected.stderr,
            actual.status.code(),
            expected.status.code()
        );
    }
    Ok(())
}

fn run_fifo_cmd(
    cmd: &Path,
    args: &[&str],
    fifo: &Path,
    data: &[u8],
    arg0_override: Option<&Path>,
) -> Result<CmdOutput> {
    let fifo_writer = fifo.to_path_buf();
    let data = data.to_vec();
    let writer = std::thread::spawn(move || -> Result<()> {
        fs::write(&fifo_writer, &data)?;
        Ok(())
    });
    let out = run_cmd_with_arg0(cmd, args, None, arg0_override)?;
    writer.join().unwrap()?;
    Ok(out)
}

fn run_fifo_cmd_to_file(
    cmd: &Path,
    args: &[&str],
    fifo: &Path,
    data: &[u8],
    arg0_override: Option<&Path>,
    output_path: &Path,
) -> Result<std::process::ExitStatus> {
    let fifo_writer = fifo.to_path_buf();
    let data = data.to_vec();
    let writer = std::thread::spawn(move || -> Result<()> {
        fs::write(&fifo_writer, &data)?;
        Ok(())
    });
    let status = run_cmd_to_file(cmd, args, None, arg0_override, output_path)?;
    writer.join().unwrap()?;
    Ok(status)
}

fn compare_fifo_outputs(
    h: &Harness,
    fifo: &Path,
    args: &[&str],
    data: &[u8],
    label: &str,
) -> Result<()> {
    let out = run_fifo_cmd(&h.wcat, args, fifo, data, Some(&h.cat))?;
    let expected = run_fifo_cmd(&h.cat, args, fifo, data, None)?;
    compare_outputs(out, expected, label)?;
    compare_fifo_output_files(h, fifo, args, data, label)
}

fn compare_fifo_output_files(
    h: &Harness,
    fifo: &Path,
    args: &[&str],
    data: &[u8],
    label: &str,
) -> Result<()> {
    let wcat_file = NamedTempFile::new_in(h.fixtures.dir.path())?;
    let cat_file = NamedTempFile::new_in(h.fixtures.dir.path())?;
    run_fifo_cmd_to_file(
        &h.wcat,
        args,
        fifo,
        data,
        Some(&h.cat),
        wcat_file.path(),
    )?;
    run_fifo_cmd_to_file(&h.cat, args, fifo, data, None, cat_file.path())?;
    let wcat_bytes = fs::read(wcat_file.path())?;
    let cat_bytes = fs::read(cat_file.path())?;
    if wcat_bytes != cat_bytes {
        bail!(
            "{label} file output mismatch (wcat {}B vs cat {}B)",
            wcat_bytes.len(),
            cat_bytes.len()
        );
    }
    Ok(())
}

fn run_status(mut cmd: Command) -> Result<()> {
    let status = cmd.status()?;
    if !status.success() {
        bail!("command failed: {:?}", cmd);
    }
    Ok(())
}

fn process_asm(output: PathBuf) -> Result<()> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .context("expected test/ to have parent")?
        .to_path_buf();
    let output = root.join(output);
    for entry in WalkDir::new(&root).into_iter().filter_map(Result::ok) {
        if !entry.file_type().is_file() {
            continue;
        }
        if entry.path().extension().and_then(|s| s.to_str()) != Some("asm") {
            continue;
        }
        let rel = entry.path().strip_prefix(&root).unwrap();
        let dest = output.join(rel);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)?;
        }
        process_one_asm(entry.path(), &dest)?;
        println!("Processed: {} -> {}", rel.display(), dest.display());
    }
    Ok(())
}

fn process_one_asm(src: &Path, dest: &Path) -> Result<()> {
    let content = fs::read_to_string(src)?;
    let mut out = String::with_capacity(content.len());
    for line in content.lines() {
        let trimmed_lead = line.trim_start();
        if trimmed_lead.starts_with(';') {
            out.push_str(line.trim_end_matches(['\r', '\n']));
            out.push('\n');
            continue;
        }
        let mut buf = String::new();
        for ch in line.chars() {
            if ch == ';' {
                break;
            }
            buf.push(ch);
        }
        let cleaned = buf.trim_end_matches([' ', '\t', '\r', '\n']).to_string();
        out.push_str(&cleaned);
        out.push('\n');
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(dest, out)?;
    Ok(())
}
