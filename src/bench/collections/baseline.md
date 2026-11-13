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

## Memory after idle — rtx and the gate Mac (Apple M3 Max, macOS 26.6.2), 2026-11-10

Probe `burst.ms` (kept with the runtime-allocator card's probes, not in the repo): a burst allocates 1M objects
holding 16-216 B strings, 2000 strings of 4-68 KiB and 40 of 2 MiB and frees them all; five bursts 0.6 s apart,
five 2 s apart, five 5 s apart, each gap an awaited timer, then 12.5 s on a timer. `main` is the region heap
before any return (rtx `~/recompiler` `2e3364dfd`, the Mac's installed `60ecbc206ed`); `500 ms` returned every
dirty free big chunk once the thread's loop had idled 500 ms (the runtime of `ac60ce49206`, never landed); `10 s`
returns a free big chunk 10 to 11 s after that chunk went unused (tree `f1d38a36964d`). Danger builds. Resident
memory is RSS on Linux and the task footprint on macOS. MB after the last burst of each gap, and the fastest
burst that followed a gap (rtx best of 3 runs under load 37-41, the Mac best of 2 under load 14-40):

| host | runtime | MB at 0.6 s gaps | 2 s | 5 s | after 12.5 s | burst ms at 0.6 s gaps | 2 s | 5 s |
|---|---|---|---|---|---|---|---|---|
| rtx | main | 432 | 435 | 436 | 436 | 402 | 399 | 367 |
| rtx | 500 ms | 238 | 234 | 234 | 234 | 426 | 400 | 407 |
| rtx | 10 s | 368 | 368 | 370 | 199 | 359 | 337 | 353 |
| Mac | main | 368 | 370 | 370 | 370 | 680 | 651 | 710 |
| Mac | 500 ms | 240 | 237 | 237 | 237 | 663 | 683 | 711 |
| Mac | 10 s | 368 | 368 | 368 | 213 | 611 | 667 | 663 |

Bursts closer than the age keep their pages, so they pay no fault for pages given back (the 500 ms runtime paid
it on Linux: 426 against 402 ms and 407 against 367 ms; on macOS `MADV_FREE_REUSABLE` changes the footprint
without unmapping, so no runtime shows it there). What stays after the return is small chunks, which keep their
pages (the 1M cells and their strings). Since tree `844c75a751e8` they
return too: §Emptied small chunks. One of the three `main` runs on rtx fell from 436 to 368 MB during its
5 s gaps; `main` returns nothing, and the cause was not looked for. Under the earlier probe (same burst, 2 s
idle) `libc` (`-DMS_HEAP_USE_MALLOC=1`) settled at 253-259 MB on rtx and 115-208 MB on m1m, and node 24.1.0
with `--expose-gc` at 421-434 MB.

A loop its host drives (`msRunOnce(0)` every frame, the wait in the host: ion, Neon) never armed the 500 ms
clock: 64 x 2 MiB freed stayed at 143 MB across 2.4 s of such turns on the Mac, against 4 MB after a waiting
loop. The 10 s runtime checks on every turn; corpus `hostDrivenLoopReturnsFreedPages` holds it.

Taking from a returned chunk, macOS footprint, one run each: one 96 MiB buffer freed and returned (1.2 MB), then
120 frames each taking and freeing a 3 MiB buffer: 97.2 MB on the 500 ms runtime, which re-armed the whole
chunk and macOS charges every re-armed page, 4.3 MB on the 10 s runtime, which re-arms the front it takes. After
64 x 2 MiB strings freed and returned the same frames cost 12.8 MB on the 500 ms runtime and 18.2 MB on the 10 s
one, whose dirty pieces no longer join returned neighbours; both are back near 2.4 MB 12.5 s later.

Not measured: Windows resident memory (d87 passes both corpus programs, which assert at least 100 MB returned),
a long-running server, and a quiet host for the burst times.

## Emptied small chunks — rtx and m1m, 2026-11-12

`main` is `e21c6e7c3666`, the msc installed on each host with its own runtime; `tree` is a copy of that msc beside
the runtime of tree `844c75a751e8`, where a freed cell goes back to its own chunk and a small chunk that stayed
empty for the return age joins the big chunks (ULTRALOCK M10, M12; guard `allocatorReturnsIdlePages`).

Memory: the burst probe of the section above with one more 12.5 s wait, danger builds, both arms running at once
on rtx under load 35-59, one run:

| runtime | MB at 0.6 s gaps | 2 s | 5 s | after 12.5 s | after 25 s | best burst ms at 0.6 s, 2 s, 5 s gaps |
|---|---|---|---|---|---|---|
| main | 367 | 367 | 367 | 194 | 194 | 648, 692, 651 |
| tree | 368 | 368 | 368 | 194 | 3 | 572, 638, 632 |

The small chunks go back 10 to 22 s after they emptied: the chunks emptied by one burst wait for the generation
before them to reach its age. Corpus `idleProgramReturnsEmptiedSmallChunks` holds the single-generation case
(2000000 objects freed, at least 80 MB back within 15 s; red on main).

Time, `collections` and `json` built `--release`, six runs per arm in alternating order on m1m at load 3.5-7.7,
not pinned. The ratio is the tree's speed over main's (least us/op, most MB/s; above 1 the tree is faster):

| bench | rows | best run, lowest to highest ratio | median run, lowest to highest ratio |
|---|---|---|---|
| collections | 18 | 0.981 (`number toString 1k`) to 1.052 (`template literal 1k`) | 0.977 to 1.050 |
| json | 12 | 0.983 (`stringify large 1 MB`) to 1.033 (`encode typed medium 64 KB`) | 0.983 to 1.060 |

```
~/metascript/.gate-host/run-remote.sh --mac --cores 2 -- bash -c 'cp "$(command -v msc)" builder
  for b in collections json; do msc build src/bench/$b/bench.ms --release --output=out/b/$b-main
    ./builder build src/bench/$b/bench.ms --release --output=out/b/$b-cand; done
  for b in collections json; do for r in 1 2 3 4 5 6; do <main then cand on odd r, cand then main on even r>; done; done'
```

The same recipe on rtx under load 27-99 (pinned, best of 6) gave ratios from 0.55 (`array push 10k`) to 2.18
(`parse large 1 MB`); m1m at low load shows neither, so the rtx rows are not kept.

Allocator alone, a C probe that includes `runtime/allocator.c` (`churn.c`, kept with the runtime-allocator card's
probes), rtx pinned to one core under load 35-59, best of 5, ns per take-and-free:

| pattern | 32 B main | tree | 256 B main | tree | 1024 B main | tree |
|---|---|---|---|---|---|---|
| one cell taken and freed in turn | 6.68 | 4.74 | 6.66 | 4.88 | 6.77 | 4.72 |
| 200k taken, freed in order | 6.09 | 6.53 | 26.80 | 29.44 | 75.29 | 82.02 |
| 200k taken, freed in random order | 119.44 | 20.75 | 164.31 | 62.37 | 208.70 | 153.61 |
| 200k live, a random half freed and retaken | 112.38 | 77.87 | 161.04 | 122.45 | 215.23 | 188.26 |

Two 3000 B cells (one cell a page) taken and freed in turn: 6.69 main, 9.27 tree: each such chunk leaves its class
when it empties and is reopened from the region's empty chunks. The remote-free probe of `src/bench/io/baseline.md`
§Remote frees in runs (owner allocates, 1, 2 or 4 threads free; 32, 256 and 1024 B) gave best runs within 16% either way except 1024 B
with 4 freers (26.8 main, 43.4 tree), and means between 8 and 722 ns under that load: not a measurement.

Not measured: Windows; x86-64 at low load for the two benches and the two probes; a long-running server; how much
stays resident when freed pages lie between small chunks still in use (a free run under 68 KiB that touches no
discarded chunk is not discarded, M12).

## A second free refused, a return in turns — rtx, d87, m1m and the gate Mac, 2026-11-12

`main` is `runtime/allocator.c`, `allocator.h` and `allocatorPages.c` of main `58fc7c4361b2`; `tree` is tree
`16b1a9932e1d`, where a freed small cell carries a mark that refuses its second free, an owner's big free
checks the in-use bit (`msHeapFreedTwice`), and a timed return does one loop turn's share
(`MS_HEAP_TURN_CELLS`, `MS_HEAP_TURN_PAGES`; guards `allocatorCoreContracts`, `allocatorReturnsIdlePages`).
Both arms are built by one candidate of the tree and differ in those three files.

One return, before the share (tree `c88529ca1b9b`), rtx under load 44, three runs: 100000 emptied small
chunks (400 MB) took 6.5-7.5 ms to route home when another thread freed them, 1.4-1.9 ms to release and
14-22 ms to discard; 1000000 took 60-68, 16-17 and 196-229 ms. With the share, a C probe that frees 1008 B
cells and then runs the loop's returns until none is due (`sweep.c`, kept with the runtime-allocator card's
probes), three runs each, longest loop turn in ms:

| emptied chunks | freed by | rtx, load 21-27 | d87, load 6 | gate Mac, load 21 |
|---|---|---|---|---|
| 10000 | their owner | 0.43-0.67 | 1.86-1.91 | 0.19-0.94 |
| 100000 | their owner | 1.01-1.46 | 2.36-2.58 | 0.66-1.19 |
| 1000000 (Mac: 500000) | their owner | 1.23-1.36 | 3.22-4.01 | 0.73-6.97 |
| 10000 | another thread | 0.42-0.67 | 1.88-2.09 | 0.25-0.59 |
| 100000 | another thread | 1.20-1.37 | 4.26-5.00 | 5.02-6.35 |
| 1000000 (Mac: 500000) | another thread | 3.79-4.17 | 35.83-38.87 | 27.45-28.33 |

The last row's long turn is the owner's one exchange of its shared list, which counts the list a step per run
(`msHeapFetchRemoteCells`): 250000 runs at 1000000 chunks. Main takes the same step at an allocation. All
chunks are back 10.7 to 11.3 s after their owner freed them and 21.7 to 22.3 s after another thread did, in 4
to 490 turns. At a share of 8192 pages d87's longest turn was 4.5-8.8 ms, which set the share to 4096.

Time, `collections` and `json` built `--release`, six runs per arm in alternating order on m1m under load
15-23, not pinned; the ratio is the tree's speed over main's:

| bench | rows | best run, lowest to highest ratio | median run, lowest to highest ratio |
|---|---|---|---|
| collections | 18 | 0.919 (`split 1k fields`) to 1.097 (`array slice 10k`) | 0.922 to 1.064 |
| json | 12 | 0.936 (`parse medium 64 KB`) to 1.020 (`stringify strings 64 KB`) | 0.919 to 1.084 |

Five rows are under 0.97 in both columns: `split 1k fields` 0.919 and 0.922, `number toString 1k` 0.934 and
0.942, `Map set/get string 10k` 0.965 and 0.965, `parse medium 64 KB` 0.936 and 0.963, `parse numbers 64 KB`
0.946 and 0.919. The section above measured the tree before the mark at 0.981 to 1.052 on the same host at
load 3.5-7.7, so the mark is the likely cause and the load is not excluded.

Allocator alone (`churn.c`), m1m under load 14-19, not pinned, best of 7, ns per take-and-free. `no check` is
the tree without the mark, its check and its clearing; `count` is a variant that was measured and not built:
no mark, the free list of a chunk counted when the chunk empties:

| pattern | main | no check | count | tree |
|---|---|---|---|---|
| one cell taken and freed in turn, 32 B | 5.76 | 5.43 | 5.85 | 6.71 |
| 200k taken, freed in order, 32 B | 6.12 | 6.07 | 8.00 | 8.22 |
| 200k taken, freed in random order, 32 B | 15.25 | 7.95 | 11.26 | 9.92 |
| 200k live, a random half freed and retaken, 32 B | 15.35 | 10.24 | 10.62 | 12.88 |
| one cell taken and freed in turn, 256 B | 5.79 | 5.36 | 5.80 | 6.71 |
| 200k taken, freed in order, 256 B | 18.82 | 13.49 | 22.92 | 20.31 |
| 200k taken, freed in random order, 256 B | 102.59 | 21.20 | 39.01 | 27.53 |
| 200k live, a random half freed and retaken, 256 B | 71.55 | 47.94 | 46.74 | 54.36 |
| one cell taken and freed in turn, 1024 B | 5.79 | 5.37 | 5.82 | 6.71 |
| 200k taken, freed in order, 1024 B | 49.15 | 29.61 | 28.51 | 36.74 |
| 200k taken, freed in random order, 1024 B | 135.33 | 63.35 | 62.84 | 68.32 |
| 200k live, a random half freed and retaken, 1024 B | 95.98 | 77.94 | 87.27 | 79.31 |
| two 3000 B cells taken and freed in turn | 6.29 | 8.44 | 9.05 | 9.14 |

The same probe on rtx, pinned to one core under load 18-25, best of 7:

| pattern | main | no check | count | tree |
|---|---|---|---|---|
| one cell taken and freed in turn, 32 B | 3.82 | 3.21 | 3.14 | 2.90 |
| 200k taken, freed in order, 32 B | 3.82 | 4.30 | 4.94 | 4.42 |
| 200k taken, freed in random order, 32 B | 95.02 | 6.84 | 14.75 | 7.22 |
| 200k live, a random half freed and retaken, 32 B | 55.85 | 18.51 | 9.94 | 12.76 |
| one cell taken and freed in turn, 256 B | 4.14 | 3.24 | 2.89 | 2.80 |
| 200k taken, freed in order, 256 B | 28.61 | 26.89 | 30.78 | 27.42 |
| 200k taken, freed in random order, 256 B | 147.51 | 39.46 | 60.20 | 56.04 |
| 200k live, a random half freed and retaken, 256 B | 135.06 | 98.14 | 87.13 | 111.34 |
| one cell taken and freed in turn, 1024 B | 3.56 | 2.97 | 2.83 | 2.90 |
| 200k taken, freed in order, 1024 B | 86.99 | 79.20 | 78.60 | 75.60 |
| 200k taken, freed in random order, 1024 B | 189.75 | 130.98 | 146.57 | 129.70 |
| 200k live, a random half freed and retaken, 1024 B | 241.59 | 175.33 | 156.30 | 178.59 |
| two 3000 B cells taken and freed in turn | 3.93 | 6.89 | 6.11 | 6.07 |

On rtx the mark shows no cost on a cell that is in the cache (the tree is within 0.4 ns of `no check`, on either
side); in the nine rows that free cold cells the tree differs from `no check` by -5.8 to +16.6 ns, on either
side, which that load does not resolve. On m1m the mark costs 1.3 ns on a cell that is in the cache and 1.4 to 7.1 ns where the probe frees a cell it last
touched 200000 cells earlier, because the free now reads the cell. Rejected with these rows: the mark without
clearing it when the cell is taken (73.77 and 259.92 ns for 32 B freed in order and in random order: a cell
whose second word the program never wrote still matches, and each such free walks its chunk's list); counting
on empty in place of the mark (slower than the mark in 4 of the 13 rows, and it stops a second free only when
its chunk empties).

```
~/metascript/.gate-host/run-remote.sh --mac --cores 2 -- env BURST=0 bash probeSmall/bench.sh
~/metascript/.gate-host/run-remote.sh --mac --cores 2 --no-msc -- bash probeSmall/parts.sh
~/metascript/.gate-host/run-remote.sh --host rtx --cores 2 --no-msc -- bash probeSmall/parts.sh
~/metascript/.gate-host/run-remote.sh --windows --cores 2 --no-msc -- bash probeSweep/sweep.sh
```

`probeSmall/` and `probeSweep/` are the card's `small/tree` and `small/sweep` copied into the tree for the run.

Not measured: the two benches on x86-64, and the churn probe there at low load (a quiet window on rtx was asked for
at 15:30 and had not opened by 22:00); the remote-free probe on this tree; the cost of the mark in a program
that frees cold buffers.

## The free path's shape — quiet rtx, 2026-11-13

A quiet window on rtx (load 1-6, no other job placed there, bench pinned to one core), six runs per arm,
`main` the three allocator files of main `75dcf5ff94f9`. Before the change below (tree `a5627fecf703`) the
tree was under main by 13% on `template literal 1k` (best 18.79 against 21.51 us), 9-10% on `number
toString 1k` and `split 1k fields`, 7-9% on `parse small object` and `parse numbers 64 KB`. Two probe arms,
each the tree with one part taken out, both came back to main's speed (`template literal 1k` 18.29 and 18.25
us): the empty-chunk shelving and the second-free mark do not cost that time themselves. The compiled
`msHeapFree` does (clang -O2, arm64): main saves one register pair at entry and calls nothing on the small
path; the tree called `msHeapPutHome` out of line and inlined the big-chunk free with its clock read, saving
three pairs on every free. With the cold paths out of line (`msHeapDeallocBig`, `msHeapShelveSmall`,
`msHeapRelistSmall`, `msHeapIsHome` noinline, `msHeapPutHome` always inline, the region's count taken after
the refusal check), `msHeapFree` saves one pair again. Best of six, ratio the tree's speed over main's:

| row | main | tree | ratio |
|---|---|---|---|
| template literal 1k, us/op | 18.96 | 19.58 | 0.969 |
| number toString 1k, us/op | 9.313 | 8.883 | 1.048 |
| split 1k fields, us/op | 7.566 | 7.951 | 0.952 |
| array push 10k, us/op | 5.216 | 4.822 | 1.082 |
| sort 10k numbers, us/op | 644.4 | 674 | 0.956 |
| parse small object, us/op | 0.593 | 0.613 | 0.967 |
| parse numbers 64 KB, MB/s | 581.4 | 568.9 | 0.979 |
| parse large 1 MB, MB/s | 281.8 | 294.9 | 1.047 |
| encode typed medium 64 KB, MB/s | 400.9 | 444.5 | 1.109 |

The other 21 rows lie within 0.979 (`parse medium 64 KB`) and 1.049 (`decode typed medium 64 KB`). Between runs of identical code `array push 10k` moved from 0.94
to 1.08, so a row inside about 5% of main is not separated from that spread. The allocator probe (`churn.c`)
in the same window, ns per operation, best of five:

| pattern | main | tree |
|---|---|---|
| one cell taken and freed in turn, 32 B | 3.44 | 2.39 |
| 200k taken, freed in random order, 32 B | 13.36 | 5.81 |
| 200k taken, freed in random order, 256 B | 91.15 | 28.36 |
| 200k live, a random half freed and retaken, 256 B | 66.42 | 39.21 |
| 200k taken, freed in random order, 1024 B | 127.71 | 70.06 |
| two 3000 B cells taken and freed in turn | 3.54 | 5.02 |

The last row stays slower: a 3000 B cell fills its chunk, so each free empties a chunk that is not its class's
head and shelves it, and the next take opens it again. Not measured yet: the tree with the change on m1m.
