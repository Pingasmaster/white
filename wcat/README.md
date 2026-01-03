# White cat (wcat)

An amd64 assembly rewrite of `cat`. It supports every cat feature except -u and non-C locales without relying on libc while being around 5 times faster than the original GNU cat.

## Building
Requirements: `nasm` and `ld` (from binutils) on a Linux amd64 system.

```sh
dd if=/dev/random of=wcat/testfile bs=250M count=1 # Generate random test file, yes I can't put it in the github so you'll have to do it yourself
cd wcat
nasm -f elf64 wcat.asm -o wcat.o && ld -o wcat wcat.o # Build
sudo cp wcat /usr/bin/ # Install
```

## Running
Examples:

```sh
./wcat/wcat file.txt              # cat file
./wcat/wcat -nE file1 file2       # line numbers + $ end markers
printf 'data\n' | ./wcat/wcat -T  # visualize tabs from stdin
./wcat/wcat -- -leading-dash.txt  # treat dash-prefixed name as operand
```

Use shell redirection/pipes exactly like traditional `cat`.

## Performance

#### Cases where cat was faster in theory

These are mainly edge cases which prove to what point the C compiler is optimized to run great assembly, despite the best manual assembly I could write.

- --show-all --number control.txt (cat ~6.87x faster)
- stdin blanks -s (cat ~2.55x faster)
- stdin + file --number (cat ~1.43x faster)
- stdin control --show-all (cat ~1.15x faster)
- --number big.txt (cat ~1.07x faster)
- stdin big.txt (cat ~1.03x faster)
- -nE big.txt (cat ~1.02x faster)

#### Cases where cat was faster on-disk

- plain big.txt (cat ~1.16x faster)
- plain bench_big.txt (cat ~1.02x faster)
- stdin big.txt (cat ~2.21x faster)
- -E big.txt (cat ~1.49x faster)
- -nE big.txt (cat ~1.33x faster)
- -bE blanks.txt (cat ~1.93x faster)
- -sE blanks.txt (cat ~37.61x faster)
- --show-all --number control.txt (cat ~1.13x faster)
- stdin tabs -T (cat ~2.94x faster)
- stdin blanks -s (cat ~1.09x faster)
- stdin control --show-all (tie, 2.60ms vs 2.60ms)

#### Benchmark table

Case                                | wcat mean (/dev/null) | cat mean (/dev/null) | winner (/dev/null) | cat/wcat (/dev/null) | wcat mean (disk) | cat mean (disk) | winner (disk) | cat/wcat (disk)
------------------------------------+-----------------------+----------------------+--------------------+----------------------+------------------+-----------------+---------------+----------------
plain small2.txt                    | 239.8us               | 3.30ms               | wcat               | 13.76x               | 412.0us          | 2.80ms          | wcat          | 6.80x          
plain big.txt                       | 0.9us                 | 3.80ms               | wcat               | 4222.22x             | 666.8us          | 573.3us         | cat           | 0.86x          
plain bench_big.txt                 | 298.0us               | 14.20ms              | wcat               | 47.65x               | 16.90ms          | 16.50ms         | cat           | 0.98x          
plain testfile                      | 15.30ms               | 30.00ms              | wcat               | 1.96x                | 77.40ms          | 80.90ms         | wcat          | 1.05x          
multi small2 + big                  | 348.6us               | 4.20ms               | wcat               | 12.05x               | 349.4us          | 1.20ms          | wcat          | 3.43x          
stdin big.txt                       | 7.70ms                | 8.40ms               | wcat               | 1.09x                | 11.50ms          | 5.20ms          | cat           | 0.45x          
-n big.txt                          | 16.40ms               | 14.60ms              | cat                | 0.89x                | 14.90ms          | 15.20ms         | wcat          | 1.02x          
-b blanks.txt                       | 101.3us               | 2.20ms               | wcat               | 21.72x               | 128.9us          | 589.3us         | wcat          | 4.57x          
-s blanks.txt                       | 0.0us                 | 1.20ms               | wcat               | inf                  | 532.5us          | 1.90ms          | wcat          | 3.57x          
-E big.txt                          | 8.60ms                | 3.50ms               | cat                | 0.41x                | 9.10ms           | 6.10ms          | cat           | 0.67x          
-T tabs.txt                         | 96.5us                | 369.2us              | wcat               | 3.83x                | 663.8us          | 3.80ms          | wcat          | 5.72x          
-v control.txt                      | 241.7us               | 3.20ms               | wcat               | 13.24x               | 340.1us          | 4.20ms          | wcat          | 12.35x         
-A control.txt                      | 281.0us               | 1.70ms               | wcat               | 6.05x                | 0.0us            | 2.00ms          | wcat          | inf            
-e control.txt                      | 15.3us                | 1.80ms               | wcat               | 117.65x              | 344.2us          | 6.70ms          | wcat          | 19.47x         
-t tabs.txt                         | 332.2us               | 1.30ms               | wcat               | 3.91x                | 26.9us           | 49.0us          | wcat          | 1.82x          
-u big.txt                          | 227.4us               | 3.40ms               | wcat               | 14.95x               | 189.2us          | 3.90ms          | wcat          | 20.61x         
-nE big.txt                         | 9.50ms                | 10.60ms              | wcat               | 1.12x                | 10.90ms          | 8.20ms          | cat           | 0.75x          
-nT tabs.txt                        | 290.8us               | 2.90ms               | wcat               | 9.97x                | 23.6us           | 249.5us         | wcat          | 10.57x         
-bE blanks.txt                      | 160.5us               | 2.70ms               | wcat               | 16.82x               | 1.10ms           | 569.4us         | cat           | 0.52x          
-sE blanks.txt                      | 157.8us               | 730.2us              | wcat               | 4.63x                | 105.3us          | 2.8us           | cat           | 0.03x          
-sT tabs.txt                        | 482.2us               | 2.30ms               | wcat               | 4.77x                | 169.4us          | 1.40ms          | wcat          | 8.26x          
-As blanks.txt                      | 51.7us                | 570.6us              | wcat               | 11.04x               | 0.1us            | 1.90ms          | wcat          | 19000.00x      
-nET tabs.txt                       | 351.6us               | 868.6us              | wcat               | 2.47x                | 335.7us          | 1.00ms          | wcat          | 2.98x          
--number big.txt                    | 14.20ms               | 15.40ms              | wcat               | 1.08x                | 10.20ms          | 11.30ms         | wcat          | 1.11x          
--number-nonblank blanks.txt        | 456.5us               | 524.6us              | wcat               | 1.15x                | 190.0us          | 2.50ms          | wcat          | 13.16x         
--squeeze-blank blanks.txt          | 0.0us                 | 698.4us              | wcat               | inf                  | 725.3us          | 4.70ms          | wcat          | 6.48x          
--show-ends no_newline.txt          | 128.5us               | 1.50ms               | wcat               | 11.67x               | 38.4us           | 852.0us         | wcat          | 22.19x         
--show-tabs tabs.txt                | 138.1us               | 1.40ms               | wcat               | 10.14x               | 94.2us           | 1.60ms          | wcat          | 16.99x         
--show-nonprinting control.txt      | 731.8us               | 3.60ms               | wcat               | 4.92x                | 4.1us            | 849.4us         | wcat          | 207.17x        
--show-all control.txt              | 0.0us                 | 1.00ms               | wcat               | inf                  | 58.8us           | 2.10ms          | wcat          | 35.71x         
--number --show-ends blanks.txt     | 411.1us               | 2.40ms               | wcat               | 5.84x                | 602.0us          | 2.60ms          | wcat          | 4.32x          
--number --show-tabs tabs.txt       | 118.8us               | 1.30ms               | wcat               | 10.94x               | 44.8us           | 444.9us         | wcat          | 9.93x          
--show-all --number control.txt     | 107.6us               | 1.30ms               | wcat               | 12.08x               | 537.5us          | 477.4us         | cat           | 0.89x          
--squeeze-blank --number blanks.txt | 444.4us               | 1.50ms               | wcat               | 3.38x                | 1.5us            | 908.6us         | wcat          | 605.73x        
stdin tabs -T                       | 3.80ms                | 3.10ms               | cat                | 0.82x                | 5.30ms           | 1.80ms          | cat           | 0.34x          
stdin blanks -s                     | 3.60ms                | 2.50ms               | cat                | 0.69x                | 2.40ms           | 2.20ms          | cat           | 0.92x          
stdin control --show-all            | 2.80ms                | 3.80ms               | wcat               | 1.36x                | 2.60ms           | 2.60ms          | tie           | 1.00x          
stdin + file --number               | 5.10ms                | 2.10ms               | cat                | 0.41x                | 2.30ms           | 3.00ms          | wcat          | 1.30x          
file stdin file --number-nonblank   | 5.50ms                | 11.50ms              | wcat               | 2.09x                | 1.30ms           | 6.50ms          | wcat          | 5.00x          

All benchmark were tested on a 2tb raid0 btrfs drive from 3 ssds. In general, faster "theorical" (output to /dev/null) results are indicative of real world faster performance if your drive can keep up. A fast enough drive could make those speedups a reality.

## Tests
Run the Rust harness from `test/`:

```sh
cd test
cargo run -- tests
```
