# std/core/buffer and std/fs bench baseline

Each table is one `src/bench/run.sh io 3` run: the median of three runs per arm, each run itself the median of three
rounds of at least 250 ms. `candidate` is std Buffer and std/fs on the C backend built `--release`; `node` is
`bench.node.mjs` on node's `Buffer` and `node:fs`. The command:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- sh -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger --lto=off --output=msc-cand && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> src/bench/run.sh io 3'
```

The hosts are shared, so a table carries its load; compare a new run against the table of the same host only.

What the rows compare:

- std/fs is synchronous and has no file handle, so node's rows use its `*Sync` calls, and `fs append` reopens the file
  for each write in both arms (`appendFile`, `appendFileSync`). The fs rows time the page cache of a temp dir, not the
  disk.
- `fs stat size` is std `fileSize` against node `statSync(path).size`, which also builds a `Stats` object.
- std `slice` copies; node's row copies too (`Buffer.from(buf.subarray(...))`), since node's `slice` is a view.
- `alloc 1 MB` reads only the length afterwards in both arms, so no page is touched: its MB/s is allocation time per
  megabyte, not memory bandwidth.
- The utf8 rows use mixed ASCII and multibyte text; node converts to and from its UTF-16 strings there, std's strings
  are UTF-8 already.

## m1m — Apple M1 Pro, macOS arm64, node 24.1.0

Commit `80f4952e8bf`, tree `e51ad6d2df3`, 2026-11-04, load 2.5 before, 2.4 after (8 cores).

| row | unit | candidate | node |
|---|---|---|---|
| alloc 1 KB | us/op | 0.047 | 0.181 |
| alloc 1 MB | MB/s | 1231696 | 114994 |
| from string utf8 1 MB | MB/s | 24425 | 522.7 |
| toString utf8 1 MB | MB/s | 1808 | 617.1 |
| base64 encode 1 MB | MB/s | 1960 | 16459 |
| base64 decode 1 MB | MB/s | 685.5 | 8194 |
| hex encode 1 MB | MB/s | 1888 | 1997 |
| hex decode 1 MB | MB/s | 7415 | 1531 |
| concat 2x512 KB | MB/s | 72354 | 30068 |
| slice copy 64 KB | MB/s | 31511 | 28634 |
| copyTo 64 KB | MB/s | 26085 | 25839 |
| indexOf byte 1 MB | MB/s | 2148 | 43076 |
| indexOf 16 B needle 1 MB | MB/s | 5141 | 43029 |
| fs write+read 4 KB | MB/s | 71.28 | 70.92 |
| fs write+read 1 MB | MB/s | 2782 | 2682 |
| fs readFile utf8 1 MB | MB/s | 1673 | 572 |
| fs stat size | us/op | 1.483 | 1.759 |
| fs readdir 32 entries | us/op | 25.73 | 27.45 |
| fs append 100x64 B | us/op | 2174 | 2209 |

## rtx — AMD Ryzen 9 9950X, Linux x86_64, node 24.1.0

Commit `5e328c6222e`, tree `082d453c198`, 2026-11-04, load 9.0 before, 4.8 after (32 threads).

| row | unit | candidate | node |
|---|---|---|---|
| alloc 1 KB | us/op | 0.015 | 0.634 |
| alloc 1 MB | MB/s | 199926 | 18633 |
| from string utf8 1 MB | MB/s | 50639 | 1264 |
| toString utf8 1 MB | MB/s | 4753 | 879.2 |
| base64 encode 1 MB | MB/s | 3399 | 13801 |
| base64 decode 1 MB | MB/s | 1413 | 12875 |
| hex encode 1 MB | MB/s | 3188 | 2590 |
| hex decode 1 MB | MB/s | 11284 | 2231 |
| concat 2x512 KB | MB/s | 85195 | 13764 |
| slice copy 64 KB | MB/s | 111999 | 15923 |
| copyTo 64 KB | MB/s | 120126 | 105228 |
| indexOf byte 1 MB | MB/s | 5246 | 218393 |
| indexOf 16 B needle 1 MB | MB/s | 7214 | 223793 |
| fs write+read 4 KB | MB/s | 1499 | 1111 |
| fs write+read 1 MB | MB/s | 7295 | 5680 |
| fs readFile utf8 1 MB | MB/s | 4345 | 828.2 |
| fs stat size | us/op | 0.2 | 0.408 |
| fs readdir 32 entries | us/op | 2.796 | 3.885 |
| fs append 100x64 B | us/op | 98.61 | 108.2 |

The rows behind node on both hosts are Buffer `indexOf` (byte 20x on m1m and 42x on rtx, 16-byte needle 8.4x and 31x)
and base64 (encode 8.4x and 4.1x, decode 12x and 9.1x); `hex encode` is within 6% on m1m. The fs rows tie or lead.

## The region heap against libc — rtx, 2026-11-08

Three arms, built on rtx with three compilers, each reading its own `runtime/`: `region heap` is main `804c40e867a`
(tree `f954f3def3d`), the first main whose desktop programs allocate from the region heap; `heap off` is the same tree
with `MS_HEAP_ENABLED 0` in `runtime/allocator.h` (allocation through libc); `before the allocator` is main
`44612a83c22` (tree `a49fc6310ad`). In the io run, `nm` showed `msHeapAlloc` only in the first arm's binary. The arms ran
interleaved, six runs each, and each row keeps its best run, because the load
(26.42, 36.16, 42.43 before, 19.81, 57.91, 56.09 after) moved a five-round median by
more than the differences measured here. `heap / off` is the region heap's speed over the heap-off arm's (above 1 is
faster). Heap off matches the pre-allocator main on every row (0.97-1.08), so the column isolates the allocator.

| row | unit | region heap | heap off | before the allocator | heap / off |
|---|---|---|---|---|---|
| alloc 1 KB | us/op | 0.01 | 0.015 | 0.015 | 1.50 |
| alloc 1 MB | MB/s | 188870 | 192243 | 183424 | 0.98 |
| from string utf8 1 MB | MB/s | 47901 | 49348 | 50153 | 0.97 |
| toString utf8 1 MB | MB/s | 4600 | 4630 | 4387 | 0.99 |
| base64 encode 1 MB | MB/s | 29277 | 28833 | 29808 | 1.02 |
| base64 decode 1 MB | MB/s | 30829 | 30406 | 30690 | 1.01 |
| hex encode 1 MB | MB/s | 3104 | 3052 | 3122 | 1.02 |
| hex decode 1 MB | MB/s | 11574 | 11581 | 11767 | 1.00 |
| concat 2x512 KB | MB/s | 87939 | 87362 | 83430 | 1.01 |
| slice copy 64 KB | MB/s | 102694 | 112398 | 113216 | 0.91 |
| copyTo 64 KB | MB/s | 93766 | 118865 | 119947 | 0.79 |
| indexOf byte 1 MB | MB/s | 170612 | 216301 | 220109 | 0.79 |
| indexOf 16 B needle 1 MB | MB/s | 171057 | 222459 | 222337 | 0.77 |
| fs write+read 4 KB | MB/s | 1454 | 1466 | 1465 | 0.99 |
| fs write+read 1 MB | MB/s | 6786 | 7012 | 6930 | 0.97 |
| fs readFile utf8 1 MB | MB/s | 4214 | 4278 | 3972 | 0.98 |
| fs stat size | us/op | 0.21 | 0.212 | 0.212 | 1.01 |
| fs readdir 32 entries | us/op | 2.668 | 2.808 | 2.813 | 1.05 |
| fs append 100x64 B | us/op | 100.2 | 102.1 | 103.1 | 1.02 |

```
~/metascript/.gate-host/run-remote.sh --cores 2 --host rtx -- bash -c '
  for arm in cand noheap pre; do M=<that arm's compiler: 804c40e867a, the same tree with the heap off, 44612a83c22>
    $M build src/bench/io/bench.ms --release --output=out/io-$arm; done
  for r in 1 2 3 4 5 6; do for arm in cand noheap pre; do ./out/io-$arm | sed "s/^/$arm\t/"; done; done'
```

Why the four slower rows are slower; probes and counters were pinned to one core (`taskset -c 31`) on the same arms:

- **indexOf byte, indexOf 16 B needle (0.79, 0.77): the libc arm scans the zero page.** `scan` is `Buffer.alloc(1 MB)`
  with 16 bytes written. libc `calloc` returns fresh `mmap` pages that nothing touches, and every one of them maps the
  kernel's shared zero page, so `memchr` reads one 4 KB page from L1: L1-dcache-load-misses 0.2M against 328M, the
  same 1.968e9 instructions, 515M against 693M cycles. The region heap zeroes what it hands out, as the reference
  does (Nim `rawAlloc0` → `zeroMem`), so its pages are real and the scan runs at L2 speed. Real buffers have been
  written; the row measures an untouched one. Transparent huge pages are not involved (`madvise` mode, 0 KB
  `AnonHugePages` in both arms).
- **copyTo, slice copy (0.79, 0.91): 4K aliasing between source and destination.** Both arms copy with the same libc
  `__memmove_avx512_unaligned_erms` (95-99.9% of samples). Moving the destination of a 64 KB copy across a page gives
  the same curve in both arms: within about 64-256 bytes of the source's page offset 77-91 GB/s, farther 100-115 GB/s.
  The region heap puts every big chunk's payload at the page-aligned chunk plus a fixed header, so two big buffers
  always share a page offset, the slow end; glibc packs chunks with 16-byte headers and its offsets fall where the
  sizes put them. The reference places big chunks the same way (Nim `15dd34468` `lib/system/alloc.nim:1085-1091`,
  `addr(c.data)` of a page-aligned chunk), with no offset or colouring.

Open: spreading big-chunk payload offsets (jemalloc's `cache_oblivious` random cache-line offset, not traced yet)
would move these rows off the slow end. Placement changes no program's result, so it is not a divergence from the
reference (`~/metascript/CLAUDE.md` §Language behaviour); it waits on a trace and an A/B.

## Calloc skips memory fresh from the OS — rtx and m1m, 2026-11-08

`msHeapCalloc` now zeroes only memory that has been handed out before: a big chunk carries a `zeroed` bit (set when
its pages come from `mmap`/`VirtualAlloc`, inherited by a split, cleared on free and on every coalesce) and a small
chunk remembers whether its bump area came from such a chunk; a cell from a free list is always zeroed. The bare and
Wasm page sources reuse their storage, so they never claim zero (`MS_HEAP_FRESH_PAGES_ZERO`). Nim zeroes every
`rawAlloc0` (`15dd34468` `lib/system/alloc.nim:1115-1117`); the tracking follows mimalloc's `free_is_zero`
(`v1.8.7` `src/segment.c:621`, `v3.1.5` `src/arena.c:183-185,702`) and jemalloc's extent `zeroed` flag (`5.3.0`
`src/extent.c:145,763,1198,1281`). Every program keeps its result, so this is not a divergence. Pinned by the guard
`allocatorZeroOnlyWhenDirty` (red on the previous `allocator.c` and on a free that keeps the bit).

Two arms on one candidate compiler (tree of this change), differing only in `runtime/allocator.{c,h}` (main
`038c602e732` for `base`), interleaved best of 8; rtx pinned to one core (`taskset -c 31`). Rows that moved the same way in every run (three on m1m, four on rtx):

| host | row | cand | base | speed |
|---|---|---|---|---|
| rtx | indexOf byte 1 MB (MB/s) | 219123 | 171586 | 1.28 |
| rtx | indexOf 16 B needle 1 MB (MB/s) | 219888 | 169396 | 1.30 |
| m1m | toString utf8 1 MB (MB/s) | 1811 | 1402 | 1.29 |
| m1m | fs readFile utf8 1 MB (MB/s) | 1682 | 1322 | 1.27 |

The indexOf rows now match the libc arm above (216301 / 222459), which closes their cause. Rows that moved in one run
and not in another on the same code are left out, among them m1m `slice copy 64 KB` (0.80-1.55 across four runs) and
`alloc 1 MB` (bimodal 47-107 GB/s within one process, P-core against E-core; 75 interleaved runs gave best 107264
against 106163), rtx `array slice 10k` (0.94, then 1.00 pinned). Not measured: Windows.

## Realloc in place and spread big payloads — rtx, 2026-11-08

Two runtime changes, each keeping every program's result. Realloc copies by the block's own size, as the reference
does (Nim `15dd34468` `lib/system/alloc.nim:1329-1337`), keeps the block when the new size still fits with at most half
of it unused (mimalloc `v2.1.7` `src/alloc.c:246`), and grows a big chunk into its free right neighbour (jemalloc
`5.3.0` `src/large.c:84-128`); array growth zeroes only the tail not known to be zero (Rust `grow_zeroed`). Big payloads
start at a deterministic multiple of 64 bytes inside the chunk's slack, stride 27 over 64 slots (jemalloc
`opt_cache_oblivious`, `arena_inlines_b.h:427-450`, without its extra page), so two big buffers rarely share a page
offset. Pinned by `allocatorCoreContracts`, `allocatorZeroOnlyWhenDirty` and `allocatorThreadRegions`.

Three arms on one candidate compiler: `base` is the runtime of main `d3033574822`, `realloc` adds the first change,
`full` both. Interleaved best of 8, pinned to one core (`taskset -c 31`), load 15-22 (other gates). Rows outside
0.95-1.05 against `base`:

| row | realloc | full |
|---|---|---|
| copyTo 64 KB (MB/s) | 0.88 | 1.16 (118220; the libc arm above is 119947) |
| slice copy 64 KB (MB/s) | 1.00 | 1.16 |
| array push 10k (us/op, collections) | 1.09 | 1.11 |
| array spread 10k (us/op, collections) | — | 1.14 |
| toString utf8 1 MB (MB/s) | 0.93 | 0.93 |
| fs readFile utf8 1 MB (MB/s) | 0.93 | 0.94 |

The two utf8 rows run no realloc (`utf8String` allocates, scans and copies). The same loop alone, with the setup's
`repeat` and `fromString`, has identical instructions in all three arms (4.0840e10) and cycles 5.57-5.70e9 in each, so
the row moves with where the bench's earlier buffers leave the heap, not with a slower path. `copyTo` under `realloc`
alone (0.88) is the same placement effect, which the spread removes. Not measured: Windows; m1m runs of these arms
moved 0.8-2.3x between runs on the copy rows (P/E-core placement) and are left out.
