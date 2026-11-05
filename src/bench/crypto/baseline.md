# std/crypto bench baseline

Each table is one `src/bench/run.sh crypto 3` run: the median of three runs per arm, each run itself the median of
three rounds of at least 250 ms. `candidate` is std/crypto on the C backend built `--release`; `js` is the same
`bench.ms` built `--target=js` and run by node, so an async row there is WebCrypto and a Sync row is the portable
code of `std/crypto/pure`; `node` is `bench.node.mjs` on node:crypto, always its synchronous call. The command:

```
~/metascript/.gate-host/run-remote.sh <host flags> -- sh -c 'cp "$(command -v msc)" builder && \
  ./builder build src/index.ms --danger --lto=off --output=msc-cand && \
  MSC=./msc-cand MSBENCH_COMMIT=<sha> src/bench/run.sh crypto 3'
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

Commit `43cc3103de9`, tree `be370ad7937`, 2026-11-05, load 2.73 before, 1.25 after (32 threads), `--cores 2`.

| row | unit | candidate | js | node |
|---|---|---|---|---|
| sha256 digest 32 B | us/op | 0.046 | 1.412 | 0.922 |
| sha256 digest 1 KB | MB/s | 2392 | 131 | 767 |
| sha256 digest 64 KB | MB/s | 2677 | 157 | 2584 |
| sha256 digest 1 MB | MB/s | 2663 | 157 | 2680 |
| sha512 digest 64 B | us/op | 0.206 | 8.744 | 1.065 |
| sha512 digest 1 MB | MB/s | 724 | 9.7 | 1551 |
| sha256 digest 1 MB async | MB/s | 2655 | 1332 | 2681 |
| sha1 digest 1 MB | MB/s | 1073 | 180 | 2823 |
| md5 digest 1 MB | MB/s | 1001 | 361 | 1144 |
| blake2b-512 digest 1 MB | MB/s | 848 | 25.8 | 1886 |
| hmac-sha256 32 B | us/op | 0.182 | 6.251 | 1.343 |
| pbkdf2-sha256 100k | us/op | 7654 | 11788 | 11547 |
| hkdf-sha256 32 B | us/op | 0.462 | 16.09 | 5.301 |
| randomBytes 32 B | us/op | 0.136 | 1.41 | 1.274 |
| argon2id t3 m4M p1 | us/op | 1694 | 117780 | - |
| ed25519 sign 64 B | us/op | 21.3 | 21.8 | 16.8 |
| ed25519 signSync 64 B | us/op | 21.2 | 188.5 | 16.7 |
| ed25519 verify 64 B | us/op | 59.2 | 57.1 | 46.8 |
| x25519 shared | us/op | 40.4 | 26.7 | 21.0 |
| aes-256-gcm seal 1 MB | MB/s | 6763 | 263 | 3463 |
| aes-256-gcm open 1 MB | MB/s | 7216 | 263 | 3580 |
| aes-256-gcm sealSync 1 MB | MB/s | 6752 | 43.9 | 3496 |
| aes-256-cbc encrypt 1 MB | MB/s | 1001 | 221 | 1349 |
| chacha20-poly1305 seal 1 MB | MB/s | 3536 | 73.4 | 3365 |
| chacha20-poly1305 open 1 MB | MB/s | 3546 | 74.4 | 3304 |
| rsa-2048 sign pkcs1 64 B | us/op | 3022 | 233 | 169 |
| rsa-2048 verify pkcs1 64 B | us/op | 74.0 | 34.9 | 12.7 |
| rsa-2048 oaep decrypt 32 B | us/op | 2975 | 235 | 170 |
| ecdsa-p256 sign 64 B | us/op | 166 | 23.0 | 13.2 |
| ecdsa-p256 verify 64 B | us/op | 581 | 41.7 | 34.4 |
| ecdh-p256 shared | us/op | 390 | 86.7 | 51.7 |
| sha256 stream 16x64 KB | MB/s | 2628 | 155 | 2679 |

C rows behind node: RSA-2048 (sign and decrypt 18x, verify 6x) and P-256 (sign 13x, verify 17x, ECDH 8x) on mbedTLS
PSA; sha1 (2.6x), blake2b-512 (2.2x) and sha512 (2.1x) at 1 MB; aes-256-cbc (1.35x); the three 25519 rows (1.2-1.9x).

JS rows: WebCrypto reaches node's speed only where a call carries little data (RSA, ECDSA, Ed25519, X25519, PBKDF2).
On 1 MB inputs it runs at a tenth of node (aes-gcm 263 vs 3463 MB/s) or half (sha256 async 1332 vs 2681), because
`Buffer` on JS is a plain `Array` and each call copies it into a `Uint8Array` and back (`msAesGcmSeal` and
`msAesBytes` in `std/crypto/aes/index.jms`). The Sync rows run the portable code and are 4x (ed25519 signSync) to
160x (sha512) behind node; argon2id takes 118 ms per hash against 1.7 ms on C.

### rtx, 2026-11-04, the C-only table

Commit `2c3a0e48024`, tree `184c43ae6c1`, 2026-11-04, load 14.7 before, 6.5 after (32 threads).

| row | unit | candidate | node |
|---|---|---|---|
| sha256 digest 32 B | us/op | 0.047 | 0.851 |
| sha256 digest 1 KB | MB/s | 2344 | 856 |
| sha256 digest 64 KB | MB/s | 2611 | 2564 |
| sha256 digest 1 MB | MB/s | 2648 | 2713 |
| sha512 digest 64 B | us/op | 0.202 | 1.287 |
| sha512 digest 1 MB | MB/s | 741 | 1564 |
| hmac-sha256 32 B | us/op | 0.174 | 1.207 |
| pbkdf2-sha256 100k | us/op | 7839 | 11521 |
| hkdf-sha256 32 B | us/op | 0.442 | 5.604 |
| randomBytes 32 B | us/op | 0.134 | 1.494 |
| ed25519 sign 64 B | us/op | 20.8 | 17.0 |
| ed25519 verify 64 B | us/op | 57.8 | 46.1 |
| x25519 shared | us/op | 39.7 | 21.3 |
| aes-256-gcm seal 1 MB | MB/s | 6890 | 3324 |
| chacha20-poly1305 seal 1 MB | MB/s | 3594 | 3432 |
| sha256 stream 16x64 KB | MB/s | 2631 | 2593 |

The rows behind node are sha512 at 1 MB (half of node's speed; on m1m it ties), the three 25519 rows, and, within
3%, sha256 at 1 MB.
