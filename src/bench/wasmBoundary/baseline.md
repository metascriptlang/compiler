# wasmBoundary baseline

Command, from the recompiler root on m1m (quiet window, `run-remote.sh --host m1m --quiet 25`):

```bash
source ~/projects/emsdk/emsdk_env.sh; export PATH=$HOME/.cargo/bin:$PATH
MSC=./msc src/bench/run.sh wasmBoundary 5 && node src/bench/wasmBoundary/accept.mjs
```

Arms: `mixed` is `bench.ms` built `--target=js --danger` with its `@wasm` functions in wasm; `jsonly`
is the same program with `--wasm-placement=off`; `neon` is the same rows in Rust through neon-bindings
1.1.2 (N-API, native, `neon/`); `wasmbindgen` is the same rows in Rust compiled to
`wasm32-unknown-unknown` with wasm-bindgen 0.2.130 glue (`wasmbindgen/`). Every arm runs the shared
harness (`src/bench/harness.mjs`). A row named `x1000` is one op of 1000 calls, so its `us/op` reads
as ns per call; the other rows are one call per op.

## 2026-11-07, m1m

Apple M1 Pro, Darwin arm64, node v24.1.0, Emscripten 5.0.5, cargo 1.99.1, commit `5b4883a0e3b`
(main `804c40e867a` plus the bench), load 5.94 before, 4.13 after. Median of 5 rounds, us/op.

| row | mixed | jsonly | neon | wasmbindgen | accept |
|---|---|---|---|---|---|
| add x1000 | 2.828 | 0.484 | 39.833 | 11.63 | ok |
| add64 x1000 | 4.619 | 2.014 | 52.428 | 4.266 | ok |
| strLen16 x1000 | 39.167 | 6.046 | 70.999 | 25.256 | slower than wasmbindgen |
| echo16 x1000 | 140.53 | 0.325 | 86.213 | 150.348 | slower than neon |
| mid x1000 | 52.096 | 0.886 | 362.634 | 327.395 | ok |
| sumVec 1k Array | 1.718 | 3.045 | 51.814 | 1.471 | slower than wasmbindgen |
| sumSpan 1k Float32Array | 1.035 | 2.687 | 1.038 | 1.006 | ok |
| scaleSpan 1k Float32Array | 0.283 | 0.518 | 0.157 | 0.414 | slower than neon |
| makeVec 1k | 2.574 | 3.297 | 0.853 | 0.925 | slower than neon, wasmbindgen |
| callback 1k | 6.7 | 0.428 | 49.517 | 114.513 | ok |
| primes 2M | 5764.027 | 20702.453 | 4420.19 | 5230.478 | slower than neon, wasmbindgen |

`accept: 5/11 rows meet neon and wasmbindgen (mixed at most 10% above)`. A busy-host run of the same
tree an hour earlier (load 14 → 7, 3 rounds) gave the same verdicts with every median within 3%.

Differences between the arms that are not the boundary: `makeVec` returns a JS `Array` on `mixed`
(a `Vec<float32>` is an Array in JS) and a `Float32Array` on the Rust arms; `neon` runs native code,
so `primes` and the in-place `scaleSpan` measure native against wasm there; wasm-bindgen's `mid`
allocates a `Point` in wasm per call and frees it, its idiomatic struct path.
