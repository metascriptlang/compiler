# iteration bench baseline

Each table is one `src/bench/run.sh iter 3` run: the median of three runs per arm, each run itself the median of
three rounds of at least 250 ms. Every row is one walk over 65536 int32 values (a 256x256 grid for the nested row).
`candidate` is `bench.ms` on the C backend built `--release` by the tree's compiler; `rust` is `bench.rs` built
`rustc -C opt-level=3`; `nim` is `bench.nim` built `nim c -d:danger` (Nim 2.2.2, ORC); `node` is `bench.node.mjs`.
`ms/rust` and `ms/nim` divide the candidate's time by the twin's; **slower** marks a row more than 10% behind Rust.
The command:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- sh -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger --lto=off --output=msc-cand >/dev/null && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> [MSBENCH_RUST=<bin>] [MSBENCH_NIM=<bin>] src/bench/run.sh iter 3'
```

Neither host had Nim, and m1m had no Rust, on 2026-11-04, so those twins were built on the Mac and passed in
prebuilt: Rust 1.98.1 for darwin arm64, Nim 2.2.2 for darwin arm64 (Apple clang) and for linux x86_64 (`zig cc
-target x86_64-linux-gnu.2.28`, zig 0.16.0, `-O3`). The hosts are shared, so a table carries its load; compare a new
run against the table of the same host only.

## rtx — AMD Ryzen 9 9950X, Linux x86_64, node 24.1.0, rustc 1.99.1

Commit `f96cdf53d8f` (compiler as `0bb8fbaec38`), 2026-11-04, load 48.4 before, 18.7 after (32 threads): a loaded host, so the ratios to the
twins, measured in the same minutes, carry more than the absolute numbers.

| row | candidate us/op | rust | nim | node | ms/rust | ms/nim |
|---|---|---|---|---|---|---|
| indexed for int32[] | 2.245 | 3.117 | 3.162 | 18.512 | 0.72 | 0.71 |
| for-of int32[] | 2.072 | 3.716 | 3.731 | 38.214 | 0.56 | 0.56 |
| for-of Vec<int32> | 2.161 | 3.341 | 3.149 | 300.629 | 0.65 | 0.69 |
| for-of values() | 22.783 | 4.156 | 3.189 | 35.977 | 5.48 **slower** | 7.14 |
| for-of keys() | 35.821 | 3.108 | 3.178 | 48.779 | 11.53 **slower** | 11.27 |
| for-of entries() | 18.199 | 6.412 | 6.291 | 123.124 | 2.84 **slower** | 2.89 |
| for-of nested 256x256 | 3.151 | 4.068 | 4.073 | 35.173 | 0.77 | 0.77 |
| generator | 15.724 | 4.345 | 4.185 | 482.36 | 3.62 **slower** | 3.76 |
| nested generator | 14.579 | 4.356 | 4.263 | 1083.661 | 3.35 **slower** | 3.42 |
| Iterator.range float64 | 52.716 | 34.301 | 34.259 | 478.832 | 1.54 **slower** | 1.54 |
| chain for-of | 31.633 | 18.125 | 30.354 | 1161.94 | 1.75 **slower** | 1.04 |
| chain reduce | 32.568 | 19.901 | 27.896 | 1321.699 | 1.64 **slower** | 1.17 |
| chain stored in a function | 32.661 | 18.438 | 339.626 | 1429.672 | 1.77 **slower** | 0.10 |
| map toArray | 77.104 | 7.066 | 7.825 | 2020.954 | 10.91 **slower** | 9.85 |
| zip product | 2247.244 | 7.745 | 29.792 | 2233.326 | 290.15 **slower** | 75.43 |
| eager map filter reduce | 138.3 | 22.506 | 72.314 | 1210.205 | 6.15 **slower** | 1.91 |

## m1m — Apple M1 Pro, macOS arm64, node 24.1.0

Commit `f96cdf53d8f` (compiler as `0bb8fbaec38`), 2026-11-04, load 24.1 before, 14.0 after (8 cores): a loaded host, so read this table for
its ratios and rerun it before quoting an absolute number.

| row | candidate us/op | rust | nim | node | ms/rust | ms/nim |
|---|---|---|---|---|---|---|
| indexed for int32[] | 5.651 | 3.141 | 3.989 | 49.471 | 1.80 **slower** | 1.42 |
| for-of int32[] | 5.664 | 3.14 | 4.005 | 41.912 | 1.80 **slower** | 1.41 |
| for-of Vec<int32> | 5.669 | 3.132 | 3.976 | 478.459 | 1.81 **slower** | 1.43 |
| for-of values() | 20.91 | 3.122 | 3.974 | 41.786 | 6.70 **slower** | 5.26 |
| for-of keys() | 41.781 | 3.126 | 3.955 | 52.108 | 13.37 **slower** | 10.56 |
| for-of entries() | 41.674 | 5.418 | 5.421 | 186.283 | 7.69 **slower** | 7.69 |
| for-of nested 256x256 | 7.981 | 4.355 | 4.81 | 60.04 | 1.83 **slower** | 1.66 |
| generator | 32.476 | 5.879 | 5.844 | 1109.826 | 5.52 **slower** | 5.56 |
| nested generator | 41.525 | 5.893 | 5.843 | 2230.713 | 7.05 **slower** | 7.11 |
| Iterator.range float64 | 62.562 | 62.269 | 62.24 | 1119.918 | 1.00 | 1.01 |
| chain for-of | 35.693 | 28.593 | 35.706 | 1890.146 | 1.25 **slower** | 1.00 |
| chain reduce | 35.714 | 28.843 | 35.682 | 2052.134 | 1.24 **slower** | 1.00 |
| chain stored in a function | 35.689 | 28.622 | 439.484 | 1891.928 | 1.25 **slower** | 0.08 |
| map toArray | 78.666 | 8.485 | 11.33 | 1744.48 | 9.27 **slower** | 6.94 |
| zip product | 2377.464 | 6.362 | 39.406 | 2718.833 | 373.70 **slower** | 60.33 |
| eager map filter reduce | 146.205 | 46.033 | 107.589 | 1293.421 | 3.18 **slower** | 1.36 |

The rows furthest behind Rust on both hosts are `zip product` (290x and 374x), `keys()`, `map toArray`, `values()`,
`entries()` and the generators; the plain array loops lead Rust on rtx and trail it 1.8x on m1m.
