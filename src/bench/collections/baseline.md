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

## The region heap against libc — rtx, 2026-11-08

Three arms, built on rtx with three compilers, each reading its own `runtime/`: `region heap` is main `804c40e867a`
(tree `f954f3def3d`), the first main whose desktop programs allocate from the region heap; `heap off` is the same tree
with `MS_HEAP_ENABLED 0` in `runtime/allocator.h` (allocation through libc); `before the allocator` is main
`44612a83c22` (tree `a49fc6310ad`). In the io run, `nm` showed `msHeapAlloc` only in the first arm's binary. The arms ran
interleaved, six runs each, and each row keeps its best run, because the load
(14.57, 31.45, 45.17 before, 7.36, 23.59, 38.69 after) moved a five-round median by
more than the differences measured here. `heap / off` is the region heap's speed over the heap-off arm's (above 1 is
faster). Heap off matches the pre-allocator main on every row (0.98-1.01), so the column isolates the allocator.

| row | unit | region heap | heap off | before the allocator | heap / off |
|---|---|---|---|---|---|
| string += 1k | us/op | 2.05 | 2.075 | 2.067 | 1.01 |
| template literal 1k | us/op | 19.06 | 17.68 | 17.46 | 0.93 |
| number toString 1k | us/op | 8.591 | 8.426 | 8.426 | 0.98 |
| split 1k fields | us/op | 7.555 | 16.88 | 16.79 | 2.23 |
| join 10k strings | us/op | 38.43 | 38.4 | 38.5 | 1.00 |
| indexOf 16 KB miss | us/op | 1.825 | 1.805 | 1.811 | 0.99 |
| includes 16 KB miss | us/op | 1.821 | 1.811 | 1.814 | 0.99 |
| replaceAll 16 KB | us/op | 4.515 | 4.622 | 4.546 | 1.02 |
| array push 10k | us/op | 5.456 | 4.83 | 4.798 | 0.89 |
| sort 10k numbers | us/op | 665.9 | 660.4 | 663.2 | 0.99 |
| sort 10k strings | us/op | 1318 | 1436 | 1422 | 1.09 |
| map/filter 10k | us/op | 52.24 | 52.6 | 52.33 | 1.01 |
| array slice 10k | us/op | 0.945 | 1.015 | 1.021 | 1.07 |
| array spread 10k | us/op | 0.804 | 0.69 | 0.694 | 0.86 |
| Map set/get int 10k | us/op | 206.1 | 201.3 | 202.1 | 0.98 |
| Map set/get string 10k | us/op | 393.5 | 439.2 | 440.2 | 1.12 |
| Map forEach 10k | us/op | 5.285 | 5.477 | 5.429 | 1.04 |
| Set add/has 10k | us/op | 219.4 | 215.1 | 217 | 0.98 |

```
~/metascript/.gate-host/run-remote.sh --cores 2 --host rtx -- bash -c '
  for arm in cand noheap pre; do M=<that arm's compiler: 804c40e867a, the same tree with the heap off, 44612a83c22>
    $M build src/bench/collections/bench.ms --release --output=out/collections-$arm; done
  for r in 1 2 3 4 5 6; do for arm in cand noheap pre; do ./out/collections-$arm | sed "s/^/$arm\t/"; done; done'
```

Why the three slower rows are slower (pinned to one core, `perf record` and `perf stat`):

- **array push 10k (0.89): growth copies.** The region heap's realloc is alloc, copy, free, as the reference's is
  (Nim `15dd34468` `lib/system/alloc.nim:1329-1337`); glibc `realloc` grows the block in place. memmove takes 17.5%
  of the region heap arm's cycles and does not appear in the libc arm's profile (1.75e9 against 1.44e9 cycles). The
  `memset` of new capacity (11-14%) is in both arms.
- **array spread 10k (0.86): the 80 KB copy between two big chunks**, the same 4K aliasing as io `copyTo` above, plus
  big-chunk get and release at 4% against glibc's 2% (1.87e9 against 1.64e9 cycles, the same L1 misses).
- **template literal 1k (0.93): 3% when pinned (372 against 361 ms), not traced further.** Allocation plus free cost
  the same in both arms (about 335M cycles each); the extra cycles show in `msStringConcatArr` and memmove. Moving
  the output string by 0, 8 or 64 cells does not change it, so it is not cell placement.

## Memory after idle — rtx and m1m, 2026-11-10

Probe `idle.ms` (kept with the runtime-allocator card's probes, not in the repo): each round allocates 1M objects
holding 16-216 B strings, 2000 strings of 4-68 KiB and 40 of 2 MiB, frees them all, then awaits a 2 s timer, so the
loop idles. `main` is the region heap before idle return (`~/recompiler` main `5f707391f` on rtx, installed
`cc97a2f5818` on m1m); `idle return` is that tree with it; `libc` is the same tree built with
`-DMS_HEAP_USE_MALLOC=1`; node runs the same shape with `--expose-gc` and a `gc()` after each free. Resident memory
is RSS on Linux and the task footprint on macOS, which is what the OS charges. One run per column, MB:

| host | column | peak | round 1 idle | round 2 idle | round 3 idle |
|---|---|---|---|---|---|
| rtx | main | 359.1 | 359.1 | 367.1 | 429.2 |
| rtx | idle return | 358.3 | 255.0 | 216.3 | 243.4 |
| rtx | libc | 414.5 | 252.9 | 258.8 | 258.8 |
| rtx | node 24.1.0 | 449.0 | 426.1 | 429.6 | 434.1 |
| m1m | main | 364.9 | 364.9 | 370.8 | 371.3 |
| m1m | idle return | 358.0 | 256.9 | 218.8 | 245.7 |
| m1m | libc | 404.4 | 132.0 | 114.6 | 207.8 |
| m1m | node 24.1.0 | 444.1 | 421.1 | 425.7 | 426.8 |

What stays after idle return is small chunks, which keep their pages (the 1M cells and their strings, about
200 MB). The cost is paid by the first burst after an idle: rtx, best of 5 interleaved runs under load 14-47,
churn time per round main 355 / 301 / 309 ms, idle return 359 / 339 / 336 ms (round 1 has no idle before it);
the pages given back fault in again. m1m shows no such cost in one run (816 / 806 against 809 / 789 ms), because
`MADV_FREE_REUSABLE` changes the footprint without unmapping. Not measured: Windows resident memory after idle
(d87 passed `idleProgramReturnsFreedPages`, which asserts at least 100 MB returned), and a long-running server.
