# std core string, array, Map and Set bench baseline

Each table is one `src/bench/run.sh collections 3` run: the median of three runs per arm, each run itself the median
of three rounds of at least 250 ms. `candidate` is the C backend built `--release`; `node` is `bench.node.mjs`. The
command:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- sh -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger --lto=off --output=msc-cand && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> src/bench/run.sh collections 3'
```

The hosts are shared, so a table carries its load; compare a new run against the table of the same host only. A run
on rtx at a 5-minute load of 30 moved rows up to 3.7x (`sort 10k numbers` 2370 against 632 us/op), so the table below
is a rerun at low load.

Both arms sort numbers with the same comparator `(a, b) => a - b`, and iterate a Map with `forEach`, since a
MetaScript `for..of` over a Map yields keys where JS yields entries. `map/filter 10k` has no reduce step yet: `reduce`
with an integer seed on a `number[]` is refused (compiler inbox card
`2026-10-28-reduce-refuses-a-named-function-and-an-unannotated-lambda`); the step returns when it lands.

## m1m — Apple M1 Pro, macOS arm64, node 24.1.0

Commit `80f4952e8bf`, tree `e51ad6d2df3`, 2026-11-04, load 9.5 before, 3.5 after (8 cores). A rerun at `5e328c6222e`
(load 9.8 to 14.7) reproduced every row within 6.3%, except the two shortest: `array slice` ran twice as fast in both
arms, and `array spread` ran 2.3x faster in node and 13% slower in the candidate.

| row | unit | candidate | node |
|---|---|---|---|
| string += 1k | us/op | 5.19 | 3.39 |
| template literal 1k | us/op | 61.85 | 7.818 |
| number toString 1k | us/op | 28.47 | 8.731 |
| split 1k fields | us/op | 27.75 | 25.12 |
| join 10k strings | us/op | 69.28 | 119 |
| indexOf 16 KB miss | us/op | 4.335 | 4.34 |
| includes 16 KB miss | us/op | 4.35 | 4.319 |
| replaceAll 16 KB | us/op | 11.84 | 13.57 |
| array push 10k | us/op | 48.31 | 22.57 |
| sort 10k numbers | us/op | 917.5 | 1360 |
| sort 10k strings | us/op | 1506 | 1910 |
| map/filter 10k | us/op | 343.8 | 172.5 |
| array slice 10k | us/op | 5.302 | 2.897 |
| array spread 10k | us/op | 14.67 | 3.278 |
| Map set/get int 10k | us/op | 386 | 557 |
| Map set/get string 10k | us/op | 821.6 | 673.9 |
| Map forEach 10k | us/op | 34.24 | 99.47 |
| Set add/has 10k | us/op | 384.1 | 506.9 |

## rtx — AMD Ryzen 9 9950X, Linux x86_64, node 24.1.0

Commit `5e328c6222e`, tree `082d453c198`, 2026-11-04, load 3.6 before, 2.5 after (32 threads).

| row | unit | candidate | node |
|---|---|---|---|
| string += 1k | us/op | 2.051 | 1.953 |
| template literal 1k | us/op | 18.6 | 5.563 |
| number toString 1k | us/op | 8.343 | 6.656 |
| split 1k fields | us/op | 16.48 | 12.71 |
| join 10k strings | us/op | 37.78 | 97.25 |
| indexOf 16 KB miss | us/op | 1.793 | 1.831 |
| includes 16 KB miss | us/op | 1.805 | 1.818 |
| replaceAll 16 KB | us/op | 4.538 | 7.215 |
| array push 10k | us/op | 4.766 | 17.08 |
| sort 10k numbers | us/op | 632 | 1042 |
| sort 10k strings | us/op | 1392 | 1375 |
| map/filter 10k | us/op | 50.81 | 116.4 |
| array slice 10k | us/op | 1.014 | 3.053 |
| array spread 10k | us/op | 6.658 | 2.98 |
| Map set/get int 10k | us/op | 199.1 | 394.5 |
| Map set/get string 10k | us/op | 433.8 | 516 |
| Map forEach 10k | us/op | 5.257 | 69.18 |
| Set add/has 10k | us/op | 218.1 | 340.8 |

Behind node on both hosts: `template literal` (7.9x on m1m, 3.3x on rtx), `number toString` (3.3x, 1.25x),
`array spread` (4.5x, 2.2x), `split` (1.1x, 1.3x) and `string +=` (1.5x, 1.05x). Behind on m1m only: `array push`
(2.1x), `map/filter` (2.0x), `array slice` (1.8x) and `Map set/get string` (1.2x), the rows that allocate most; on rtx
the same rows lead node by 1.2 to 3.6x.
