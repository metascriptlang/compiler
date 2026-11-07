# std/core/json bench baseline

Each table is one `src/bench/run.sh json 3` run: the median of three runs per arm, each run itself the median of
three rounds of at least 250 ms. `candidate` is std/core/json on the C backend built `--release`; `js` is the same
`bench.ms` built `--target=js` and run by node; `raiser` is `msc run --target=raiser`; `node` is
`bench.node.mjs` on V8's `JSON`. The arms are listed in `arms`; the 2026-11-04 tables predate `js` and `raiser`. The command:

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

## After the JSON arc — 2026-11-07

Commit `0430e5f016b`, tree `769becddfc3`, which carries the region allocator (`75d931660bd`). Both runs took a quiet
window (`run-remote.sh --host <host> --quiet 15`); the checksums match the 2026-11-04 runs.

### rtx

Load 1.16 before, 1.70 after (one-minute average).

| row | unit | candidate | js | raiser | node |
|---|---|---|---|---|---|
| parse small object | us/op | 0.56 | 1.545 | 48.643 | 0.441 |
| parse medium 64 KB | MB/s | 308.1 | 134.1 | 3.77 | 383.7 |
| parse large 1 MB | MB/s | 291.6 | 132.9 | 3.554 | 339.8 |
| parse numbers 64 KB | MB/s | 535.6 | 164.8 | 3.994 | 897.2 |
| parse strings 64 KB | MB/s | 906.4 | 34.05 | 9.29 | 1638 |
| stringify small object | us/op | 0.265 | 0.623 | 21.72 | 0.245 |
| stringify medium 64 KB | MB/s | 849.9 | 101.2 | 4.639 | 878 |
| stringify large 1 MB | MB/s | 826.6 | 72.69 | 0.442 | 636.2 |
| stringify numbers 64 KB | MB/s | 564.9 | 326.8 | 7.868 | 415.8 |
| stringify strings 64 KB | MB/s | 700.4 | 34.26 | 13.05 | 1215 |
| decode typed medium 64 KB | MB/s | 214.4 | 167.7 | 2.975 | 384.3 |
| encode typed medium 64 KB | MB/s | 388.7 | 98.7 | 4.154 | 892.5 |

### m1m

Load 39.3 before (the jobs that ended as the window opened), 4.81 after (one-minute average, 8 cores).

| row | unit | candidate | js | raiser | node |
|---|---|---|---|---|---|
| parse small object | us/op | 1.183 | 1.816 | 68.97 | 0.546 |
| parse medium 64 KB | MB/s | 152.9 | 102.3 | 2.629 | 307.5 |
| parse large 1 MB | MB/s | 152 | 106.7 | 2.664 | 249.4 |
| parse numbers 64 KB | MB/s | 274.5 | 109.2 | 2.523 | 565.4 |
| parse strings 64 KB | MB/s | 350.4 | 23.86 | 5.18 | 603.8 |
| stringify small object | us/op | 0.55 | 1.125 | 32.39 | 0.367 |
| stringify medium 64 KB | MB/s | 459.8 | 71.66 | 1.765 | 572.7 |
| stringify large 1 MB | MB/s | 452.1 | 61.65 | 0.186 | 557.7 |
| stringify numbers 64 KB | MB/s | 370.3 | 203.9 | 3.406 | 241.6 |
| stringify strings 64 KB | MB/s | 327.5 | 22.96 | 6.833 | 1374 |
| decode typed medium 64 KB | MB/s | 110 | 109.3 | 2.078 | 303.3 |
| encode typed medium 64 KB | MB/s | 197.8 | 70.66 | 1.693 | 570.9 |

Every candidate row is faster than the 2026-11-04 table of its host: on rtx by 1.56x (stringify numbers) to 5.5x
(stringify large), on m1m by 2.0x (stringify strings) to 6.9x (stringify medium). Against node, the C backend is ahead on
`stringify numbers` on both hosts and on `stringify large` on rtx, and 3% behind on `stringify medium` on rtx. Parse stays
behind node by 1.2 to 1.8x on rtx and 1.6 to 2.2x on m1m, and the typed rows by 1.8 to 2.3x on rtx and 2.8 to 2.9x on
m1m. The `js` arm loses most on strings with escapes (34 against 1638 MB/s on rtx).
