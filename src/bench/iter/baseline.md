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

Main `39e4132d6c2` (the same patch measured on its tree before a docs-only rebase), 2026-11-06, load 5.3 before,
3.4 after (32 threads). The Nim twin was cross-built on the Mac: `nim c -d:danger --opt:speed --cpu:amd64 --os:linux
--cc:clang --clang.exe:<wrapper running zig cc -target x86_64-linux-gnu.2.28>`, Nim 2.2.2, zig 0.16.0.

| row | candidate us/op | rust | nim | node | ms/rust | ms/nim |
|---|---|---|---|---|---|---|
| indexed for int32[] | 1.931 | 3.035 | 3.109 | 14.036 | 0.64 | 0.62 |
| for-of int32[] | 1.786 | 3.057 | 3.113 | 36.596 | 0.58 | 0.57 |
| for-of Vec<int32> | 1.667 | 3.057 | 3.088 | 287.588 | 0.55 | 0.54 |
| for-of values() | 12.354 | 3.091 | 3.04 | 35.485 | 4.00 **slower** | 4.06 |
| for-of keys() | 31.823 | 3.03 | 3.047 | 48.323 | 10.50 **slower** | 10.44 |
| for-of entries() | 17.376 | 6.046 | 6.061 | 123.522 | 2.87 **slower** | 2.87 |
| for-of nested 256x256 | 2.548 | 3.842 | 3.852 | 33.653 | 0.66 | 0.66 |
| generator | 12.683 | 3.801 | 3.779 | 461.496 | 3.34 **slower** | 3.36 |
| nested generator | 12.725 | 3.799 | 3.788 | 1063.348 | 3.35 **slower** | 3.36 |
| Iterator.range float64 | 37.065 | 32.802 | 32.875 | 479.3 | 1.13 **slower** | 1.13 |
| chain for-of | 20.775 | 16.432 | 25.992 | 1123.699 | 1.26 **slower** | 0.80 |
| chain reduce | 20.649 | 16.057 | 26.12 | 1318.889 | 1.29 **slower** | 0.79 |
| chain stored in a function | 21.601 | 16.592 | 308.085 | 1097.858 | 1.30 **slower** | 0.07 |
| map toArray | 28.386 | 5.544 | 6.714 | 1318.427 | 5.12 **slower** | 4.23 |
| zip product | 1106.19 | 7.41 | 26.297 | 1553.431 | 149.28 **slower** | 42.07 |
| eager map filter reduce | 105.038 | 21.305 | 67.369 | 980.435 | 4.93 **slower** | 1.56 |

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
