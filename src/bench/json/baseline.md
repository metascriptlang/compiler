# std/core/json bench baseline

Each table is one `src/bench/run.sh json 3` run: the median of three runs per arm, each run itself the median of
three rounds of at least 250 ms. `candidate` is std/core/json on the C backend built `--release`; `node` is
`bench.node.mjs` on V8's `JSON`. The command:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- sh -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger --lto=off --output=msc-cand && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> src/bench/run.sh json 3'
```

The hosts are shared, so a table carries its load; compare a new run against the table of the same host only.

Both arms build the same ASCII inputs and print `check` lines to stderr (input lengths, and length and checksum of
every stringify output); they matched on both hosts. The parse and stringify rows go through `JSON.parseValue` and
`stringify(JsonValue)`; the typed rows through `JSON.parse<Payload>` and `JSON.stringify<Payload>` on structs. Node has
no checked typed decode: its `decode typed` row is `JSON.parse` plus a read of every field the struct decode fills, so
the candidate does slightly more work there.

## m1m — Apple M1 Pro, macOS arm64, node 24.1.0

Commit `80f4952e8bf`, tree `e51ad6d2df3`, 2026-11-04, load 3.5 before, 2.4 after (8 cores).

| row | unit | candidate | node |
|---|---|---|---|
| parse small object | us/op | 2.648 | 0.554 |
| parse medium 64 KB | MB/s | 58.48 | 305.7 |
| parse large 1 MB | MB/s | 59.45 | 250.9 |
| parse numbers 64 KB | MB/s | 74.8 | 575.5 |
| parse strings 64 KB | MB/s | 119.3 | 622.6 |
| stringify small object | us/op | 2.651 | 0.362 |
| stringify medium 64 KB | MB/s | 66.93 | 574.6 |
| stringify large 1 MB | MB/s | 68.39 | 562.9 |
| stringify numbers 64 KB | MB/s | 171.9 | 248.4 |
| stringify strings 64 KB | MB/s | 162.9 | 1378 |
| decode typed medium 64 KB | MB/s | 44.41 | 299.3 |
| encode typed medium 64 KB | MB/s | 51.42 | 580 |

## rtx — AMD Ryzen 9 9950X, Linux x86_64, node 24.1.0

Commit `5e328c6222e`, tree `082d453c198`, 2026-11-04, load 17.9 before, 9.4 after (32 threads).

| row | unit | candidate | node |
|---|---|---|---|
| parse small object | us/op | 1.003 | 0.454 |
| parse medium 64 KB | MB/s | 131.8 | 368.9 |
| parse large 1 MB | MB/s | 131.2 | 326.1 |
| parse numbers 64 KB | MB/s | 136.5 | 884.1 |
| parse strings 64 KB | MB/s | 334.7 | 1587 |
| stringify small object | us/op | 0.856 | 0.247 |
| stringify medium 64 KB | MB/s | 196.7 | 859 |
| stringify large 1 MB | MB/s | 150.6 | 622 |
| stringify numbers 64 KB | MB/s | 362.2 | 407.2 |
| stringify strings 64 KB | MB/s | 423.7 | 1185 |
| decode typed medium 64 KB | MB/s | 99.46 | 366.5 |
| encode typed medium 64 KB | MB/s | 126.1 | 864.2 |

Every row is behind node on both hosts: parse by 4.2 to 7.7x on m1m and 2.2 to 6.5x on rtx, stringify of objects and
strings by 7.3 to 8.6x on m1m and 2.8 to 4.4x on rtx, and the typed rows by 6.7 to 11x on m1m and 3.7 to 6.9x on rtx.
Only `stringify numbers` comes close, 1.4x on m1m and 1.1x on rtx.
