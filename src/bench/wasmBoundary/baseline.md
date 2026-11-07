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

## 2026-11-08, m1m

Same machine and toolchains, main `0fd7cd6b524` (argument encoders return the pointer; owned ASCII
strings up to 24 chars take a short path). A `--quiet 25` window, but load 22.3 before and 11.4 after
from work outside the host picker; every row the change does not reach is within 3% of the
2026-11-07 table. Median of 5 rounds, us/op.

| row | mixed | jsonly | neon | wasmbindgen | accept |
|---|---|---|---|---|---|
| add x1000 | 2.876 | 0.482 | 40.431 | 11.58 | ok |
| add64 x1000 | 4.731 | 2.058 | 53.303 | 4.359 | ok |
| strLen16 x1000 | 23.408 | 6.098 | 72.298 | 25.835 | ok |
| echo16 x1000 | 124.377 | 0.324 | 87.974 | 151.796 | slower than neon |
| mid x1000 | 52.871 | 0.884 | 368.506 | 327.485 | ok |
| sumVec 1k Array | 1.715 | 3.019 | 52.568 | 1.48 | slower than wasmbindgen |
| sumSpan 1k Float32Array | 1.029 | 2.69 | 1.038 | 1.007 | ok |
| scaleSpan 1k Float32Array | 0.283 | 0.527 | 0.158 | 0.423 | slower than neon |
| makeVec 1k | 2.633 | 3.388 | 0.868 | 0.895 | slower than neon, wasmbindgen |
| callback 1k | 6.82 | 0.429 | 49.557 | 116.98 | ok |
| primes 2M | 5771.215 | 21252.292 | 4436.433 | 5224.994 | slower than neon, wasmbindgen |

`accept: 6/11 rows meet neon and wasmbindgen (mixed at most 10% above)`.

## 2026-11-08, m1m, after the adopted Vec argument

Main `0c9e750d5af` (a Vec argument crosses as a payload the wasm side adopts). A `--quiet 25` window,
load 9.7 before and 2.4 after. Median of 5 rounds, us/op.

| row | mixed | jsonly | neon | wasmbindgen | accept |
|---|---|---|---|---|---|
| add x1000 | 2.843 | 0.481 | 40.023 | 11.665 | ok |
| add64 x1000 | 4.74 | 2.034 | 53.197 | 4.34 | ok |
| strLen16 x1000 | 23.135 | 6.118 | 71.884 | 25.187 | ok |
| echo16 x1000 | 120.906 | 0.324 | 86.674 | 149.548 | slower than neon |
| mid x1000 | 51.802 | 0.882 | 367.201 | 326.27 | ok |
| sumVec 1k Array | 1.48 | 3.026 | 52.33 | 1.471 | ok |
| sumSpan 1k Float32Array | 1.026 | 2.68 | 1.036 | 1.002 | ok |
| scaleSpan 1k Float32Array | 0.282 | 0.516 | 0.158 | 0.412 | slower than neon |
| makeVec 1k | 2.547 | 3.283 | 0.812 | 0.922 | slower than neon, wasmbindgen |
| callback 1k | 6.855 | 0.428 | 49.601 | 114.471 | ok |
| primes 2M | 5732.016 | 20705.047 | 4399.302 | 5165.419 | slower than neon, wasmbindgen |

`accept: 7/11 rows meet neon and wasmbindgen (mixed at most 10% above)`.

Differences between the arms that are not the boundary: `makeVec` returns a JS `Array` on `mixed`
(a `Vec<float32>` is an Array in JS) and a `Float32Array` on the Rust arms; `neon` runs native code,
so `primes` and the in-place `scaleSpan` measure native against wasm there; wasm-bindgen's `mid`
allocates a `Point` in wasm per call and frees it, its idiomatic struct path.
