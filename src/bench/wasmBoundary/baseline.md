# wasmBoundary baseline

Command, from the recompiler root on m1m (quiet window, `run-remote.sh --host m1m --quiet 25`):

```bash
source ~/projects/emsdk/emsdk_env.sh; export PATH=$HOME/.cargo/bin:$PATH
export CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MSC=./msc src/bench/run.sh wasmBoundary 5 && node src/bench/wasmBoundary/accept.mjs
```

Arms: `mixed` is `bench.ms` built `--target=js --danger` with its `@wasm` functions in wasm; `jsonly`
is the same program with `--wasm-placement=off`; `neon` is the same rows in Rust through neon-bindings
1.1.2 (N-API, native, `neon/`); `wasmbindgen` is the same rows in Rust compiled to
`wasm32-unknown-unknown` with wasm-bindgen 0.2.130 glue (`wasmbindgen/`). `mixed-chrome` and `wasmbindgen-chrome` are the
`mixed` and `wasmbindgen` builds run in headless Chrome through `src/test/wasmmix/browser/runPage.mjs`
(skipped without `CHROME`). Every arm runs the shared
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

## 2026-11-08, m1m, with the callee-held row

Same tree plus the `scaleBox` row: the 1000 floats live on the callee's side and are scaled in
place, through a `Handle<VecBox<float32>>` on `mixed`, a `JsBox` holding a `Vec<f32>` on `neon`,
and a `#[wasm_bindgen]` struct holding a `Vec<f32>` on `wasmbindgen`, so no arm copies.
`scaleSpan` stays the copy row: wasm cannot address a JS-owned buffer, so a writable Span is
copied in and back, as wasm-bindgen's `&mut [f32]` is; `neon` scales the JS buffer natively.
A `--quiet 25` window, load 8.9 before and 2.9 after. Median of 5 rounds, us/op.

| row | mixed | jsonly | neon | wasmbindgen | accept |
|---|---|---|---|---|---|
| add x1000 | 2.825 | 0.481 | 39.726 | 11.656 | ok |
| add64 x1000 | 4.616 | 2.006 | 51.29 | 4.326 | ok |
| strLen16 x1000 | 22.945 | 5.916 | 70.991 | 25.191 | ok |
| echo16 x1000 | 121.041 | 0.324 | 84.904 | 150.782 | slower than neon |
| mid x1000 | 51.73 | 0.883 | 362.285 | 327.001 | ok |
| sumVec 1k Array | 1.484 | 3.011 | 51.401 | 1.464 | ok |
| sumSpan 1k Float32Array | 1.025 | 2.702 | 1.036 | 1.003 | ok |
| scaleSpan 1k Float32Array | 0.277 | 0.516 | 0.155 | 0.413 | slower than neon |
| scaleBox 1k held by callee | 0.117 | 1.014 | 0.094 | 0.187 | slower than neon |
| makeVec 1k | 2.572 | 3.288 | 0.816 | 0.819 | slower than neon, wasmbindgen |
| callback 1k | 6.679 | 0.429 | 48.817 | 115.061 | ok |
| primes 2M | 5729.638 | 20704.143 | 4403.99 | 5167.635 | slower than neon, wasmbindgen |

`accept: 7/12 rows meet neon and wasmbindgen (mixed at most 10% above)`. A handle call with no
loop measured 0.013 us (probe, same day), against about 0.04 us per neon call (`add x1000`), so
`scaleBox` trails `neon` in the scaling loop itself: wasm SIMD against native code, the class of
`primes`, not the boundary.

Differences between the arms that are not the boundary: `makeVec` returns a JS `Array` on `mixed`
(a `Vec<float32>` is an Array in JS) and a `Float32Array` on the Rust arms; `neon` runs native code,
so `primes` and the in-place `scaleSpan` measure native against wasm there; wasm-bindgen's `mid`
allocates a `Point` in wasm per call and frees it, its idiomatic struct path.

## 2026-11-08, m1m, the bar is wasm-bindgen on the same runtime

The arc ships JS calling wasm in the browser. MetaScript has no N-API bridge, and `neon` is a
native Node addon a page cannot load, so from this table on the bar is wasm-bindgen on the same
runtime: `mixed` against `wasmbindgen` on Node, `mixed-chrome` against `wasmbindgen-chrome` in
Chrome. `neon` stays a Node-only reference column. Main `69d3d241bb7` plus the Chrome arms,
Chrome 149.0.7827.114. A `--quiet 30` window, load 7.4 before and 1.8 after. Median of 5 rounds,
us/op.

| row | mixed | wasmbindgen | mixed-chrome | wasmbindgen-chrome | neon (reference) |
|---|---|---|---|---|---|
| add x1000 | 2.932 | 11.556 | 2.903 | 3.542 | 40.452 |
| add64 x1000 | 4.742 | 4.356 | 4.118 | 4.776 | 52.273 |
| strLen16 x1000 | 23.536 | 25.664 | 23.959 | 25.465 | 73.061 |
| echo16 x1000 | 124.203 | 154.493 | 129.333 | 213.171 | 87.178 |
| mid x1000 | 53.199 | 329.204 | 58.029 | 210.079 | 368.576 |
| sumVec 1k Array | 1.528 | 1.473 | 1.612 | 1.61 | 52.465 |
| sumSpan 1k Float32Array | 1.056 | 1.004 | 1.034 | 1.006 | 1.044 |
| scaleSpan 1k Float32Array | 0.285 | 0.423 | 0.279 | 0.434 | 0.158 |
| scaleBox 1k held by callee | 0.121 | 0.191 | 0.118 | 0.196 | 0.096 |
| makeVec 1k | 2.633 | 0.896 | 2.482 | 1.07 | 0.82 |
| callback 1k | 6.959 | 116.402 | 8.479 | 120.051 | 49.651 |
| primes 2M | 5891.718 | 5213.07 | 6064 | 5588.889 | 4491.787 |

`accept node: 10/12 rows meet wasmbindgen`, `accept chrome: 11/12 rows meet wasmbindgen-chrome`
(at most 10% above). The misses: `makeVec` on both (a `Vec<float32>` is a JS `Array`, wasm-bindgen
returns a `Float32Array`; a typed array result waits for the std typed arrays), and `primes` on
Node, 13% above (MetaScript's wasm code for the sieve, not the boundary; not traced).

## 2026-11-08, m1m, after the typed array result

Main `2ab90f5bd97`: `makeVec` returns a `Float32Array` written through a `Span` of it, as the
wasm-bindgen arm returns one. A `--quiet 30` window. Median of 5 rounds, us/op.

| row | mixed | wasmbindgen | mixed-chrome | wasmbindgen-chrome | neon (reference) |
|---|---|---|---|---|---|
| add x1000 | 2.856 | 11.528 | 2.869 | 3.475 | 39.889 |
| add64 x1000 | 4.592 | 4.248 | 4.005 | 4.653 | 51.358 |
| strLen16 x1000 | 23.294 | 25.187 | 23.477 | 24.955 | 71.747 |
| echo16 x1000 | 121.95 | 150.714 | 128.171 | 205.394 | 85.709 |
| mid x1000 | 52.39 | 326.685 | 57.438 | 206.899 | 360.561 |
| sumVec 1k Array | 1.481 | 1.466 | 1.613 | 1.593 | 51.767 |
| sumSpan 1k Float32Array | 1.026 | 1.004 | 1.027 | 1.006 | 1.036 |
| scaleSpan 1k Float32Array | 0.276 | 0.412 | 0.27 | 0.427 | 0.155 |
| scaleBox 1k held by callee | 0.117 | 0.189 | 0.118 | 0.192 | 0.095 |
| makeVec 1k | 0.643 | 0.95 | 1.166 | 1.052 | 0.823 |
| callback 1k | 6.81 | 115.012 | 8.336 | 118.5 | 48.79 |
| primes 2M | 5716.727 | 5164.906 | 6069.388 | 5575.472 | 4411.961 |

`accept node: 11/12`, `accept chrome: 11/12`. The misses: `primes` on Node, 11% above
(MetaScript's wasm code for the sieve; compiler card 2026-11-08-wasm-sieve-13-percent-behind-rust-wasm),
and `makeVec` in Chrome, 10.8% above, one run, not split yet.

## 2026-11-08, m1m, ship baseline

Branch `wt/js-wasm-one-program` at `8d9131964ef`, compiler unchanged since main `5e2b893c5bc`;
`primes 2M` on Node parked on compiler card 2026-11-08-wasm-sieve-13-percent-behind-rust-wasm. A
`--quiet 30` window. Median of 5 rounds, us/op.

| row | mixed | wasmbindgen | mixed-chrome | wasmbindgen-chrome | neon (reference) |
|---|---|---|---|---|---|
| add x1000 | 2.905 | 11.532 | 2.878 | 3.516 | 39.759 |
| add64 x1000 | 4.672 | 4.322 | 4.083 | 4.712 | 51.925 |
| strLen16 x1000 | 23.485 | 25.353 | 23.523 | 24.863 | 71.774 |
| echo16 x1000 | 122.431 | 149.133 | 127.098 | 205.933 | 85.721 |
| mid x1000 | 52.04 | 327.349 | 57.192 | 207.733 | 362.841 |
| sumVec 1k Array | 1.48 | 1.465 | 1.601 | 1.599 | 52.42 |
| sumSpan 1k Float32Array | 1.026 | 1.004 | 1.027 | 1.007 | 1.036 |
| scaleSpan 1k Float32Array | 0.278 | 0.417 | 0.272 | 0.425 | 0.158 |
| scaleBox 1k held by callee | 0.118 | 0.19 | 0.119 | 0.194 | 0.096 |
| makeVec 1k | 0.65 | 1.003 | 1.16 | 1.059 | 0.856 |
| callback 1k | 6.894 | 114.382 | 8.451 | 119.628 | 49.879 |
| primes 2M | 5717.469 | 5173.54 | 6052 | 5578.182 | 4396.824 |

`accept node: 11/12 rows meet wasmbindgen, 1 slower row(s) parked on a card`, `accept chrome:
12/12`, exit 0. `makeVec` in Chrome is 9.5% above, under the 10% bar by little. The row measures
what the rows before it leave behind: in one page, `makeVec` measured right after
`echo16 x1000` takes 1.08-1.24 us, measured before the string rows 0.74-0.81, and the same
function alone 0.76-0.79 against wasm-bindgen's 1.06-1.13 (3 to 5 rounds, m1m, not quiet). A
forced `gc()` before it keeps it at 1.06-1.15; Node shows none of it (0.64-0.71 everywhere).
Which row precedes the slow phase changes from run to run (after `echo16` in one, after `scaleBox`
in another). A Chrome CPU profile of the row early and late in one page (m1m, 2 rounds, 0.84 against
1.25 us) keeps the wasm fill loop at about 0.28 us and grows the JS taker
`new C(HEAPU8.slice(...).buffer, o, k)` from about 0.50 to 0.85 us, garbage collection from 1.5% to
5%: the cost is Chrome allocating the result's `ArrayBuffer`, which a copy result needs and
wasm-bindgen's `.slice()` pays too, so no glue change within the copy contract reaches it. Probe:
`--js-flags=--expose-gc` and `console.profile` around the rows, read through CDP
`Profiler.consoleProfileFinished`.

## 2026-11-10, m1m, members of a wasm-owned object

Branch `wt/js-wasm-one-program` on main `f0d98fca7d4`, with the constructor, the direct member
calls and the handle's pointer kept on it. New rows: `method x1000` (`h.value().bump(1)`),
`field x1000` (`h.value().n`), `construct x1000` (`Handle.retain(new Counter(i))` then
`release()`), against a `#[wasm_bindgen]` struct with a constructor, a `&mut self` method and a
`pub` field. Not a quiet window. Median of 5 rounds, us/op.

| row | mixed | wasmbindgen | mixed-chrome | wasmbindgen-chrome | neon (reference) |
|---|---|---|---|---|---|
| add x1000 | 2.89 | 11.875 | 2.933 | 3.601 | 40.894 |
| add64 x1000 | 4.817 | 4.485 | 4.15 | 4.899 | 52.844 |
| strLen16 x1000 | 23.997 | 25.94 | 24.24 | 26.058 | 73.13 |
| echo16 x1000 | 129.078 | 153.505 | 136.393 | 215.087 | 87.49 |
| mid x1000 | 53.009 | 330.062 | 58.583 | 214.943 | 372.567 |
| sumVec 1k Array | 1.525 | 1.51 | 1.648 | 1.658 | 53.015 |
| sumSpan 1k Float32Array | 1.056 | 1.035 | 1.059 | 1.038 | 1.068 |
| scaleSpan 1k Float32Array | 0.285 | 0.424 | 0.278 | 0.437 | 0.16 |
| scaleBox 1k held by callee | 0.112 | 0.192 | 0.117 | 0.197 | 0.098 |
| makeVec 1k | 1.125 | 0.891 | 1.12 | 1.095 | 0.884 |
| callback 1k | 6.906 | 117.683 | 8.646 | 121.502 | 50.339 |
| method x1000 | 3.84 | 12.968 | 4.185 | 4.472 | - |
| field x1000 | 3.917 | 2.849 | 4.397 | 4.268 | - |
| construct x1000 | 49.826 | 157.296 | 45.491 | 97.385 | - |
| primes 2M | 5920.51 | 5243.233 | 6174 | 6339.583 | 4527.603 |

`accept node: 12/15 rows meet wasmbindgen, 1 slower row(s) parked on a card`, `accept chrome:
15/15`. The Node misses: `field x1000`, 37% above, and `makeVec 1k`. `makeVec` is the garbage
collection phase recorded above, not this change: run alone in 5 interleaved rounds with only
the mixed arm, it measured 0.649 us (median) built by the installed compiler `60ecbc206ed`
without the new rows, 0.646 by the candidate without them, and 0.655 by the candidate with
them, one round of 1.023 at 42% spread. Before the direct calls, with each member call going
through `value()` and a proxy, `method x1000` measured 20.11 and `field x1000` 20.31 on Node.

## 2026-11-12, m1m, warmed rows; one-flag `enter`, cursor receiver, struct result slots

Candidate of tree `932ebf68601b` (main `3ed9ec329be6` plus the struct result slots) with the
`x1000` rows of all three sources changed as below. Not a quiet window (load 211 before from other
jobs, 8 after). Median of 5 rounds, us/op.

| row | mixed | wasmbindgen | mixed-chrome | wasmbindgen-chrome | neon (reference) |
|---|---|---|---|---|---|
| add x1000 | 2.882 | 2.516 | 3.186 | 3.889 | 40.51 |
| add64 x1000 | 4.594 | 16.059 | 4.425 | 15.542 | 62.655 |
| strLen16 x1000 | 23.641 | 26.154 | 24.088 | 25.415 | 72.966 |
| echo16 x1000 | 127.07 | 153.455 | 135.426 | 209.897 | 86.943 |
| mid x1000 | 5.12 | 324.247 | 5.802 | 214.51 | 369.148 |
| sumVec 1k Array | 1.489 | 1.466 | 1.611 | 1.598 | 52.43 |
| sumSpan 1k Float32Array | 1.026 | 1.007 | 1.026 | 1.008 | 1.036 |
| scaleSpan 1k Float32Array | 0.282 | 0.42 | 0.269 | 0.432 | 0.158 |
| scaleBox 1k held by callee | 0.111 | 0.191 | 0.114 | 0.196 | 0.096 |
| makeVec 1k | 0.679 | 0.925 | 1.174 | 1.138 | 0.852 |
| callback 1k | 6.844 | 117.263 | 8.34 | 120.419 | 49.936 |
| method x1000 | 3.124 | 3.354 | 3.717 | 4.783 | - |
| field x1000 | 3.202 | 3.283 | 3.858 | 4.502 | - |
| construct x1000 | 49.065 | 158.474 | 42.336 | 97.058 | - |
| primes 2M | 5815.505 | 5182.404 | 6010 | 6214 | 4418.832 |

`accept node: 13/15`, the misses `add x1000` (14.5% above) and the parked `primes`; `accept chrome: 15/15`.

**An `x1000` row reads its bound from a module variable and is warmed by 400 one-call ops**
(`benchWarmed`). With the constant bound `i < 1000` used until this table, wasm-bindgen's Node rows
`add x1000` and `method x1000` read 11.5 and 13 ns, and its own `field` row 2.85: `node --trace-opt`
on those rows shows its glue function `add` compiled for Maglev only, while `get n` reaches TurboFan.
The same rows warmed read 2.5 and 3.3 ns, so the earlier tables credit `mixed` with a win on `add`
and `method` it does not have. The shape cuts the other way on one row: warmed, wasm-bindgen's
`add64` reads 16 ns here and in Chrome, against 4.3 to 4.5 with the constant bound, so this table's
`ok` on `add64` compares with a wasm-bindgen that is not at its best (`mixed` 4.59 is 7% above 4.3).
Its `field` reads 2.85 with the constant bound and 3.28 warmed. Tried and not kept: warming inside
the shared harness with the bound passed as a parameter (`method` came down to 3.4, `add` stayed at
12.2); returning the row's value instead of adding it to `sink` (one `--trace-deopt` bailout instead
of 131, `add` still 12.3). Not explained: why V8 leaves the glue function in Maglev.

**Where a scalar call's time goes** (the same day, Node, hand-edited copies of the glue the installed
compiler `6db51a10fb06` emitted for `add`, `h.value().bump(1)` and `h.value().n`, warmed rows, 5
interleaved rounds, spreads under 4%, ns per call):

| glue | add | method | field |
|---|---|---|---|
| as emitted before this day | 3.23 | 3.95 | 4.05 |
| `enter()` behind one flag test | 2.83 | 3.69 | 3.80 |
| that, and the member entry borrowing its receiver | 2.81 | 3.10 | 3.24 |
| every check removed, with the borrowed receiver | 2.74 | 3.05 | 3.19 |
| wasm-bindgen 0.2.130 | 2.49 | 3.31 | 3.28 |

Removing the `try`/`die` around the call, the `dirty` test or `__msb.at` alone moved no row, so
the checks stay: together they cost 0.05 to 0.07 ns. The time was in `enter()` as a method that
tests a closure variable (0.25 to 0.40 ns) and in the member entry counting its receiver up and
down (0.6 ns; `wasm-dis` shows an i64 load, two i64 stores and a last-reference branch around the
field load, and one `i32.load` once the receiver is a `Cursor`). What is left on `add` against
wasm-bindgen is how the wrapper reaches the export: the same wrapper inside a closure that holds
the export in a `const` read 2.59 against wasm-bindgen's 2.60, where the module-scope function
read 2.81 (one probe, `add` only; the loop the JS backend emits, the Emscripten instance and the
wrapper's body each measured no difference).
