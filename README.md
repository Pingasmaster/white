<div align="center">
  <q><em>What's a compiler?</em></q>
</div>

White is a set of no-nonsense tools for now (and a complete operating system when it'll be finished) that allows you to do the things you already do right now, but faster and cleaner.

I chose this name because I wanted the white software suite to blend in, not disrupting your workflow and being not only faster, easy to audit (ok i'm kinda lying for this one because assembly), bugless (prove me wrong with a PR! haha) and secure, making you forget you're using them while being a 1 to 1 replacement of the programs you already use because I know people don't change their habits. The goal is to have a fully white system, starting by the coreutils, the package manager and the init system, and ending by the kernel (not guaranteed).

If you are screaming at your screen about memory safety, you can checkout white's rust 1:1 clone, orange, written 100% in safe rust with extremely minimal dependencies (though orange does have a performance penalty compared to white, its use is safer). (to be release later, work in progress)

I wrote all the white suite by myself. Yes, I wrote assembly by hand in 2026. Today, people sacrifice 10 to 20% of their hardware to write things in C, rust, Go or Java, for no good reason other than the fact they are too lazy to write in assembly. I recognize other languages such as C and rust have their merits (cleaner & really optimized compiler for C, memory safe and easier to audit for rust), but too much software is compromising on performance for no good reason with bad code for C and unsafe blocks which imo contradicts rust's purpose, so I took it upon myself to prove the world they were wrong to stop programming in assembly by making a copy of their programs that's significantly faster.

White's utilities are written in pure intel-style assembly (64 bits though, not 32 bits) and do not depend on libc nor any particular compiler (assembly uses an assembler which each have some specificities but this is beyond the point) and will work on any system of the architecture its written for. To get started you only need an assembler (I use nasm, may switch to GAS later on) and optionaly a "linter" and code formatter/bug finder (only needed if you are going to develop / fork the software) like juice (one of white's numerous utilities, coming later). The white software suite make heavy use of SIMD optimizations, 64-bit "trickery" and linux kernel syscalls when possible, because I wrote this for performance not to be old-school caus I want to actually use the software not just feel good for writing it "as god intended it to be" commodore-style. Each program is available in three different versions which each support one CPU architecture: amd64 (this is likely the one you need), arm64 (coming soon), and risc V (coming soon). White's philosophy was inspired by the work of God's loneliest programer, but applied to real-world problems instead of commodore-style PCs, each has its own appeal in its own right.

If you want to contribute to make things faster and have fun along the way you're more than welcome. The only thing to keep in mind is that correctness beats everything else, performance coming second, and that this is a hobby project. White is licensed under the GPLv3, but if you want for some reason the code under another license contact me and we can work something out.

Above all else, have a nice day, and enjoy the incredibly liberating feeling of your computer being faster, for free. So far this took 534 hours to make, including the time I took to learn about assembly.

## Deviations from original

(this section is temporary as only wcat is available right now)

wcat output currently matches GNU cat for all covered cases and is basically a 1:1 drop-in replacement (same options, same output for the same set of options), because white utilities are designed to be used in the real world.
The only intentional deviation is --help/--version text, quite obviously.

## Testing

(this section is temporary as only wcat is available right now)

The regression/test suite is now written in Rust and lives under `test/`.

```sh
cd test
cargo run -- tests                    # full suite
cargo run -- tests --filter fifo      # run a subset by name substring
cargo run -- tests --verbose          # show per-test/command stats
./test/bench.sh 		      # tests for performance with hyperfine, install it beforehand if needed
```

## Performance

The harness rebuilds `wcat` automatically when `wcat/wcat` or `wcat/wcat.o` are missing or older than `wcat/wcat.asm`, then compares behavior against `/bin/cat` across stdin, multi-file, flag combos, FIFOs, huge files, binaries, and error paths. Use `cargo clippy --all-targets --all-features -- -D warnings` to keep the suite warning-free.

Across 39 test cases, wcat is faster in 34 and cat in 5 for /dev/null; on-disk, wcat is faster in 28, cat in 10, with 1 tie. The geometric mean speedup (cat/wcat): 5.35x (for /dev/null theoretical benchmarks) and 4.42x (for real-drive benchmarks). Theoretical benchmark are NOT to be compared to on-disk benchmarks as a cat win can turn into a wcat win (cat being 1.01x faster for output to /dev/null turns into a wcat 1.3x victory on disk), and wcat speedups can be amplified (5x for /dev/null to 20x in real-world) or diminished (4.5x to 2x).
My end goal is that all white utilities are faster than their counterparts in every single way, whilte being a 1:1 replacement if it makes sense for that program. However this is a pre-alpha. The priority is given to the tasks that are done the most, like output to /dev/null and to a file without arguments, or combining multiple files, etc. These types of ultra-common use cases will have the main optimizing efforts.
Also, we'll use means for performance comparisons between cat or wcat as I want to be fair (wcat being one time 727.81 ± 9755.55 faster than cat would otherwise spin the average too dramatically in my favor).
