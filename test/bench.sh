#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname "$0")/.."

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine not installed (https://github.com/sharkdp/hyperfine)" >&2
  exit 1
fi

out_dir="$(mktemp -d "${TMPDIR:-/tmp}/wcat-bench.XXXXXX")"
trap 'rm -rf "$out_dir"' EXIT

fixtures_dir="$out_dir/fixtures"
mkdir -p "$fixtures_dir"
printf 'alpha\nbeta\n' > "$fixtures_dir/small.txt"
printf 'one\n\n\nthree\n\n\n' > "$fixtures_dir/blanks.txt"
printf 'col1\tcol2\nline\t2\n' > "$fixtures_dir/tabs.txt"
printf 'plain\ncontrol:\x01here\nesc:\x1bX\n' > "$fixtures_dir/control.txt"
printf 'no newline' > "$fixtures_dir/no_newline.txt"

tabs_file="$fixtures_dir/tabs.txt"
blanks_file="$fixtures_dir/blanks.txt"
control_file="$fixtures_dir/control.txt"
no_nl_file="$fixtures_dir/no_newline.txt"
small_file="$fixtures_dir/small.txt"

warmup="${WCAT_BENCH_WARMUP:-2}"
runs="${WCAT_BENCH_RUNS:-}"
hyperfine_args=(--warmup "$warmup")
if [[ -n "$runs" ]]; then
  hyperfine_args+=(--runs "$runs")
fi

bench_out_dir="$out_dir/bench"
mkdir -p "$bench_out_dir"

case_idx=1
bench_case() {
  local label="$1"
  local wcmd="$2"
  local ccmd="$3"
  local wout="$out_dir/wcat_${case_idx}.out"
  local cout="$out_dir/cat_${case_idx}.out"
  local wbench="$bench_out_dir/wcat_${case_idx}.out"
  local cbench="$bench_out_dir/cat_${case_idx}.out"

  echo
  echo "== $label =="
  echo "-- /dev/null --"
  hyperfine "${hyperfine_args[@]}" "$wcmd > /dev/null" "$ccmd > /dev/null"
  echo "-- disk output --"
  hyperfine "${hyperfine_args[@]}" "$wcmd > \"$wbench\"" "$ccmd > \"$cbench\""
  bash -c "$wcmd" > "$wout"
  bash -c "$ccmd" > "$cout"
  diff -u "$wout" "$cout"

  case_idx=$((case_idx + 1))
}

bench_case "plain small2.txt" "./wcat/wcat wcat/small2.txt" "cat wcat/small2.txt"
bench_case "plain big.txt" "./wcat/wcat wcat/big.txt" "cat wcat/big.txt"
bench_case "plain bench_big.txt" "./wcat/wcat wcat/bench_big.txt" "cat wcat/bench_big.txt"
bench_case "plain testfile" "./wcat/wcat wcat/testfile" "cat wcat/testfile"
bench_case "multi small2 + big" "./wcat/wcat wcat/small2.txt wcat/big.txt" "cat wcat/small2.txt wcat/big.txt"
bench_case "stdin big.txt" "cat wcat/big.txt | ./wcat/wcat -" "cat wcat/big.txt | cat -"

bench_case "-n big.txt" "./wcat/wcat -n wcat/big.txt" "cat -n wcat/big.txt"
bench_case "-b blanks.txt" "./wcat/wcat -b \"$blanks_file\"" "cat -b \"$blanks_file\""
bench_case "-s blanks.txt" "./wcat/wcat -s \"$blanks_file\"" "cat -s \"$blanks_file\""
bench_case "-E big.txt" "./wcat/wcat -E wcat/big.txt" "cat -E wcat/big.txt"
bench_case "-T tabs.txt" "./wcat/wcat -T \"$tabs_file\"" "cat -T \"$tabs_file\""
bench_case "-v control.txt" "./wcat/wcat -v \"$control_file\"" "cat -v \"$control_file\""
bench_case "-A control.txt" "./wcat/wcat -A \"$control_file\"" "cat -A \"$control_file\""
bench_case "-e control.txt" "./wcat/wcat -e \"$control_file\"" "cat -e \"$control_file\""
bench_case "-t tabs.txt" "./wcat/wcat -t \"$tabs_file\"" "cat -t \"$tabs_file\""
bench_case "-u big.txt" "./wcat/wcat -u wcat/big.txt" "cat -u wcat/big.txt"

bench_case "-nE big.txt" "./wcat/wcat -nE wcat/big.txt" "cat -nE wcat/big.txt"
bench_case "-nT tabs.txt" "./wcat/wcat -nT \"$tabs_file\"" "cat -nT \"$tabs_file\""
bench_case "-bE blanks.txt" "./wcat/wcat -bE \"$blanks_file\"" "cat -bE \"$blanks_file\""
bench_case "-sE blanks.txt" "./wcat/wcat -sE \"$blanks_file\"" "cat -sE \"$blanks_file\""
bench_case "-sT tabs.txt" "./wcat/wcat -sT \"$tabs_file\"" "cat -sT \"$tabs_file\""
bench_case "-As blanks.txt" "./wcat/wcat -As \"$blanks_file\"" "cat -As \"$blanks_file\""
bench_case "-nET tabs.txt" "./wcat/wcat -nET \"$tabs_file\"" "cat -nET \"$tabs_file\""

bench_case "--number big.txt" "./wcat/wcat --number wcat/big.txt" "cat --number wcat/big.txt"
bench_case "--number-nonblank blanks.txt" "./wcat/wcat --number-nonblank \"$blanks_file\"" "cat --number-nonblank \"$blanks_file\""
bench_case "--squeeze-blank blanks.txt" "./wcat/wcat --squeeze-blank \"$blanks_file\"" "cat --squeeze-blank \"$blanks_file\""
bench_case "--show-ends no_newline.txt" "./wcat/wcat --show-ends \"$no_nl_file\"" "cat --show-ends \"$no_nl_file\""
bench_case "--show-tabs tabs.txt" "./wcat/wcat --show-tabs \"$tabs_file\"" "cat --show-tabs \"$tabs_file\""
bench_case "--show-nonprinting control.txt" "./wcat/wcat --show-nonprinting \"$control_file\"" "cat --show-nonprinting \"$control_file\""
bench_case "--show-all control.txt" "./wcat/wcat --show-all \"$control_file\"" "cat --show-all \"$control_file\""

bench_case "--number --show-ends blanks.txt" "./wcat/wcat --number --show-ends \"$blanks_file\"" "cat --number --show-ends \"$blanks_file\""
bench_case "--number --show-tabs tabs.txt" "./wcat/wcat --number --show-tabs \"$tabs_file\"" "cat --number --show-tabs \"$tabs_file\""
bench_case "--show-all --number control.txt" "./wcat/wcat --show-all --number \"$control_file\"" "cat --show-all --number \"$control_file\""
bench_case "--squeeze-blank --number blanks.txt" "./wcat/wcat --squeeze-blank --number \"$blanks_file\"" "cat --squeeze-blank --number \"$blanks_file\""

bench_case "stdin tabs -T" "cat \"$tabs_file\" | ./wcat/wcat -T -" "cat \"$tabs_file\" | cat -T -"
bench_case "stdin blanks -s" "cat \"$blanks_file\" | ./wcat/wcat -s -" "cat \"$blanks_file\" | cat -s -"
bench_case "stdin control --show-all" "cat \"$control_file\" | ./wcat/wcat --show-all -" "cat \"$control_file\" | cat --show-all -"
bench_case "stdin + file --number" "cat \"$small_file\" | ./wcat/wcat --number - wcat/small2.txt" "cat \"$small_file\" | cat --number - wcat/small2.txt"
bench_case "file stdin file --number-nonblank" "printf '\\nstdin\\n' | ./wcat/wcat --number-nonblank wcat/small2.txt - wcat/small2.txt" "printf '\\nstdin\\n' | cat --number-nonblank wcat/small2.txt - wcat/small2.txt"
