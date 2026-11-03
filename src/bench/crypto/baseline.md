# std/crypto bench baseline

Each table is one `src/bench/crypto/run.sh 3` run: the median of three runs per arm, each run itself the median of
three rounds of at least 250 ms. `candidate` is std/crypto on the C backend built `--release`; `node` is
`bench.node.mjs` on node:crypto. The command:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- sh -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger --lto=off --output=msc-cand && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> src/bench/crypto/run.sh 3'
```

The hosts are shared, so a table carries its load; compare a new run against the table of the same host only.

## m1m — Apple M1 Pro, macOS arm64, node 24.1.0

Commit `2ff2a96f6a8`, tree `ed5b3421a64`, 2026-11-03, load 13.1 before, 13.5 after (8 cores).

| row | unit | candidate | node |
|---|---|---|---|
| sha256 digest 32 B | us/op | 0.078 | 0.57 |
| sha256 digest 1 KB | MB/s | 2101 | 1031 |
| sha256 digest 64 KB | MB/s | 2380 | 2344 |
| sha256 digest 1 MB | MB/s | 2341 | 2403 |
| sha512 digest 64 B | us/op | 0.134 | 0.607 |
| sha512 digest 1 MB | MB/s | 1416 | 1408 |
| hmac-sha256 32 B | us/op | 0.213 | 1.273 |
| pbkdf2-sha256 100k | us/op | 7305 | 21306 |
| hkdf-sha256 32 B | us/op | 0.718 | 6.834 |
| randomBytes 32 B | us/op | 0.28 | 1.132 |
| ed25519 sign 64 B | us/op | 35.1 | 30.7 |
| ed25519 verify 64 B | us/op | 103.5 | 85.7 |
| x25519 shared | us/op | 70.7 | 32.0 |
| aes-256-gcm seal 1 MB | MB/s | 5200 | 3203 |
| chacha20-poly1305 seal 1 MB | MB/s | 1531 | 1530 |
| sha256 stream 16x64 KB | MB/s | 2270 | 2392 |

The rows behind node are the 25519 field (Monocypher's 10x25.5-bit limbs) and, within 3 to 5%, sha256 at 1 MB.

## rtx — AMD Ryzen 9 9950X, Linux x86_64, node 24.1.0

Commit `54aa2c34607` (its bench sources differ from `2ff2a96f6a8` in comments only), tree `1aab71df209`, 2026-11-03,
load 38.7 before, 20.4 after (32 threads), so the spread is wider than on m1m. oci-u, the earlier x86 host, was
terminated that day and rtx was drained the same night: rerun this table when an x86 Linux host returns.

| row | unit | candidate | node |
|---|---|---|---|
| sha256 digest 32 B | us/op | 0.048 | 0.983 |
| sha256 digest 1 KB | MB/s | 2293 | 758 |
| sha256 digest 64 KB | MB/s | 2565 | 2492 |
| sha256 digest 1 MB | MB/s | 2579 | 2558 |
| sha512 digest 64 B | us/op | 0.207 | 1.496 |
| sha512 digest 1 MB | MB/s | 700 | 1495 |
| hmac-sha256 32 B | us/op | 0.194 | 1.702 |
| pbkdf2-sha256 100k | us/op | 8221 | 13275 |
| hkdf-sha256 32 B | us/op | 0.471 | 6.645 |
| randomBytes 32 B | us/op | 0.14 | 1.658 |
| ed25519 sign 64 B | us/op | 21.9 | 17.5 |
| ed25519 verify 64 B | us/op | 75.5 | 74.1 |
| x25519 shared | us/op | 50.8 | 30.4 |
| aes-256-gcm seal 1 MB | MB/s | 5433 | 2310 |
| chacha20-poly1305 seal 1 MB | MB/s | 3432 | 2655 |
| sha256 stream 16x64 KB | MB/s | 2576 | 2613 |

The rows behind node are sha512 at 1 MB (half of node's speed; on m1m it ties), ed25519 sign and x25519.
