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
