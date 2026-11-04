# std/http server bench baseline

Each table is one `src/bench/run.sh http 3` run: the median of three runs per arm, each run itself the median of
three rounds of at least 250 ms. `candidate` is the std/http server on the C backend built `--release`, serving on one
thread (`serveConcurrent(server, 1)`); `node` is a `node:http` server, also one thread. The command:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- sh -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger --lto=off --output=msc-cand && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> src/bench/run.sh http 3'
```

The hosts are shared, so a table carries its load; compare a new run against the table of the same host only.

How a row is timed: each arm starts its own server on 127.0.0.1 and runs the same client, `load.mjs` (raw HTTP/1.1
over `node:net`), so the server is the only variable; no host has wrk, oha or ab. The client keeps `cN` requests in
flight, and each timed call completes the oldest and issues the next, so `us/op` is time per request at that
concurrency. It checks every response for status 200 and the exact body length.

- A `new-conn` request closes its socket with a reset: a FIN close leaves every connection in TIME_WAIT on the
  client, and on macOS the rows ran out of its ~16k ephemeral ports (`EADDRNOTAVAIL`, fixed in `5e328c6222e`).
- The c16 keep-alive rows (about 4 us on rtx) may be near the client's own cost per request; there a row is a lower
  bound for its arm.
- std/http ends a response with a string only, so the echo row decodes the body (`req.bodyText()`); node's row decodes
  it too and lets `res.end` encode it again.
- The json row sends one 1024-byte body built at start in both arms: no serialization is timed.

## m1m — Apple M1 Pro, macOS arm64, node 24.1.0

Commit `5e328c6222e`, tree `082d453c198`, 2026-11-04, load 11.4 before, 15.1 after (8 cores).

| row | unit | candidate | node |
|---|---|---|---|
| hello keep-alive c1 | us/op | 46.65 | 40.81 |
| hello keep-alive c16 | us/op | 9.505 | 14.89 |
| hello new-conn c1 | us/op | 108.4 | 106.8 |
| hello new-conn c16 | us/op | 38.47 | 37.72 |
| json 1 KB keep-alive c1 | us/op | 47.51 | 42.27 |
| json 1 KB keep-alive c16 | us/op | 10.21 | 16.38 |
| post echo 64 KB c1 | MB/s | 244.4 | 444.2 |
| post echo 64 KB c16 | MB/s | 520.4 | 689.9 |

## rtx — AMD Ryzen 9 9950X, Linux x86_64, node 24.1.0

Commit `5e328c6222e`, tree `082d453c198`, 2026-11-04, load 4.6 before, 4.1 after (32 threads).

| row | unit | candidate | node |
|---|---|---|---|
| hello keep-alive c1 | us/op | 7.45 | 8.756 |
| hello keep-alive c16 | us/op | 3.664 | 5.65 |
| hello new-conn c1 | us/op | 21.01 | 21.82 |
| hello new-conn c16 | us/op | 17.83 | 16.89 |
| json 1 KB keep-alive c1 | us/op | 7.879 | 9.249 |
| json 1 KB keep-alive c16 | us/op | 3.888 | 6.314 |
| post echo 64 KB c1 | MB/s | 639.7 | 925.4 |
| post echo 64 KB c16 | MB/s | 791.3 | 1230 |

The rows behind node are the 64 KB echo on both hosts (0.55 and 0.75x on m1m, 0.69 and 0.64x on rtx) and, on m1m
only, keep-alive at one connection (1.1x slower). The new-connection rows tie on both hosts.
