# Smith — design

Status: direction approved (2026-10-03..05, in conversation); slice 1 proven
2026-10-05 and slice 2 integrated/probed 2026-10-07 (§Slice 2 — measured).
This file owns the agreed four-slice shape, the constraints that forced it and
the measurements behind the generator's surface. Csmith-derived evidence lives
in `CSMITH-STUDY.md`. The broader full-language goal confirmed 2026-10-07 is
audited in `coveragePlan.md`; its domain/oracle expansion still awaits approval.
Compiler findings are now retained and parked, not fixed within this goal.

## Goal

Find `msc` bugs — wrong code across backends / GC modes / optimization,
compiler crashes, DRC ledger violations — by random differential testing:
generate deterministic MetaScript programs, run them through the existing
corpus lanes, record divergences as reproducible bundles, reduce them, and
graduate confirmed regressions into the corpus.

## Why this shape, and not another

- MetaScript is memory-safe by construction, so Csmith's hardest problem —
  keeping the generated program single-interpretation by avoiding undefined
  behavior — mostly disappears. Our analogue of "single interpretation" is
  **cross-lane determinism**: identical stdout on C-drc / C-orc / C-danger,
  JS and raiser, and a clean SAN ledger. The fact engine Smith needs is
  scope/lifetime for closures and captures — not may-points-to over pointer
  arithmetic.
- The corpus contract (`docs/TESTING.md`, `src/test/corpus/run.ms`) already
  defines the oracle surface: deterministic stdout, byte-compare across lanes,
  no golden files, no fuzzy matching. Smith emits programs that are
  corpus-conformant **by construction** and drives those lanes; it never grows
  a second oracle or a second runner.
- Three false signals were measured on the reference and are designed out
  here, not to be re-learned: digest oracles collide; equal-failure
  comparisons read green; timeouts are usually not bugs (CSMITH-STUDY
  §Oracle, §Driver).

## Components

1. **Generator** (`tools/smith/`, written in MetaScript): seed + feature
   vector → typed, scope-aware program that prints canonical deterministic
   output. The feature vector is a swarm configuration: each construct family
   independently on/off per run (CSMITH-STUDY §Swarm).
2. **Driver**: builds and runs each program on the corpus lanes (parity set;
   SAN lane for DRC questions; raiser optional), reusing corpus runner
   semantics and known-red. Divergence = first lane pair whose outputs differ,
   or any crash / sanitizer report.
3. **Failure bundle** under `out/smith/`: seed, feature vector, generator
   commit, `msc` build and support-tree commit, per-lane outputs, divergence
   pair. Rerunning must reproduce the byte-identical source and the same lane
   outcomes.
4. **Reducer**: `creduce --not-c` with an interestingness predicate that pins
   failure identity (lane pair + symptom + type/width axis). C-Reduce's README
   claims non-C support; that claim is unverified for `.ms` and verifying it
   is part of slice 4.
5. **Graduation**: a reduced, confirmed regression becomes a corpus program
   named by invariant; the bundle is then deleted.

## Non-goals

- Not a benchmark, not a parser fuzzer (random token soup tests nothing past
  the parser), not a std-API exerciser (the corpus owns that surface), not
  distributed.
- No vendored Csmith code — mechanisms only. The reference checkout path is
  machine-local and stays on the arc card.

## Slices

1. **Smallest closed loop**: generator for one family (integer/float
   arithmetic + control flow + canonical prints), lane run via the corpus
   runner, bundle on divergence. Proven on a planted divergence.
2. **Swarm + scope/lifetime families**: feature vectors; closures, captures,
   unions, generics — the constructs whose divergence yield we actually want.
3. **SAN lane**: DRC-ledger and sanitizer divergences as bundle kinds.
4. **Reduction**: `creduce --not-c` + predicate; graduate one failure
   end-to-end into the corpus.

## Slice 1 — measured

Code: `tools/smith/` — `gen.ms` `generate`, `drive.ms` `runSeeds` /
`rerunBundle`, `features.ms` `Features`, `rng.ms` `Rng` (splitmix64). Commands
are in `../CLAUDE.md`.

### Single-interpretation surface

A generated program must print the same bytes on every lane. Which operations
may be emitted raw was measured one case per program, built
`--gc=drc` (C debug), `--gc=drc --danger --cc=clang` and `--target=js`
(node 24.1.0), on the installed `msc` v0.3.1, BUILD `719e18ad2` (tree
`da848ca9`), macOS arm64, 2026-10-05:

| case | C debug | C danger | JS | generator |
|---|---|---|---|---|
| `int32`/`int64` `+ - *` and unary `-` overflow | panic | wraps | unwrapped value (`2147483648`) | `safeAdd/Sub/Mul/Neg<T>` |
| `int8`/`int16`/unsigned `+ - *` overflow | wraps | wraps | wraps | raw |
| integer `/` `%` by zero | panic | garbage (`0`, `-7`, `5.4707704e-315`) | throws | `safeDiv/Mod<T>` |
| `int32`/`int64` `MIN / -1` | panic | wraps | throws | guarded in `safeDiv<T>` |
| `int32` `MIN % -1` | `0` | `0` | `0` | zero guard only |
| `<<` `>>` with count ≥ width or negative | masked (`1 << 32` = 1, `1 << -1` = MIN) | same | same | raw |
| to a narrower signed type out of range, `uint32` → `int32` | panic `not in range` | truncates | throws | `conv<S>To<T>` |
| `uint64` → `int64` | `-1`, no check | `-1` | `-1` | `conv` anyway: the reference range-checks |
| signed → unsigned, runtime value | truncates | truncates | truncates | raw |
| signed → unsigned, negative literal or a ternary with one | compile error `cannot convert -5 to uint64` | same | same | `wrap<S>To<T>` (`Shape` in `gen.ms`) |
| `float64` → integer, NaN / ±inf / out of range | panic | garbage | throws | `convFloat64To<T>` |
| `String(float64)`: `0.1+0.2`, `1e21`, `5e-324`, NaN, ±Infinity, `-0` | shortest round trip, JS spelling | same | same | raw |
| operands and arguments with side effects | left to right | same | same | raw — no effect discipline |
| `int32 < uint32` (implicit mixed signedness) | `false` | `false` | `true` | never emitted: the reference refuses it (inbox `2026-10-01-mixed-signedness-comparison-passes-the-checker.md`) |

Not measured: the Raiser and SAN lanes, `--release`, Windows, Linux/gcc,
`float32`, `int64` → `float64` rounding at the 2^53 edge.

The initial measurements found spelling traps: `-128 as int8` binds as
`-(128 as int8)`, so the generator writes negative literals as
`((-128) as int8)`. Regression pins `1110-uint64CompoundAssignWraps`,
`1111-negateNegativeLiteral` and `1113-comparisonPairIsNotGenericCall`
hold the compiler fixes found by slice 1; `1113` also covers parenthesized
callback-array type arguments found by the land formatter lane.

### The loop, proven

Subject `./msc` built from `wt/smith` `6e11ebbb` (tree `37d2c00c`, msc-hash
`71d8eb80_3bd0c950:22933024`), default features, lanes c/orc/danger/js/esm,
load average 30–39, 2026-10-05:

| run | wall | result |
|---|---|---|
| `run 1 30` | 59 s | 26 clean, 4 findings — the same 4 seeds on two separate runs |
| `run 1 10 --plant=backend` | 28 s | 10/10 wrong-code, split `c orc danger \| js esm` |
| `run 1 10 --plant=opt` | 29 s | 10/10 wrong-code, `danger` alone (seeds 3 and 7 also split off `js esm`: the real JS finding below) |
| `rerun` of all 24 bundles | — | 24/24 REPRODUCED: program byte-identical, every lane's output identical |
| `rerun` of a bundle with one byte appended to `program.ms`, and with `MSC` set to another build | — | both VOID, naming the cause |

The 4 unplanted findings are 2 compiler bugs, both reproduced on BUILD
`719e18ad2` as well: JS `+=` `-=` `*=` on `uint64` do not wrap to 64 bits
(seeds 3, 7, 24); C emits `--128` for `-((-128) as int8)` (also `int16`
MIN), a clang error (seed 21).

### Rejected

- **A `MSCORPUS_DIR` knob in `src/test/corpus/run.ms`.** The runner resolves
  `src/test/corpus/programs/` and `out/corpus/` against its cwd, so a sandbox
  holding that tree (the idiom of `src/test/guard/corpusEntryNames.ms`) reaches
  the same with no runner change and no gate on the runner path.
- **The lane pair from the runner's parity line.** `compareParityGroup` takes
  the first *finished* cell as base, so `A vs B` changes with scheduling (seed 3
  read `js vs danger` on one run). The bundle records a canonical split instead:
  lanes grouped by identical output (wrong-code) or by pass/fail (crash), in
  `LANE_ORDER`.

## Slice 2 — measured

Code: `features.ms` `Fam` / `swarm`; `gen.ms` `Gen` family methods;
`drive.ms` `runSeeds`; `main.ms` accepts `--swarm` for `gen` and `run`.
The per-seed vector, not the base vector, is the bundle's reproduction input.

Measured 2026-10-07 on macOS arm64, base tree
`639c4eb55166f23c31a4a75e4707859a48065868` with uncommitted slice 2 sources
(generator hash `9e18949_f562f177:39015`); subject `./msc` v0.3.2,
hash `dd5a2867_65a6d9a5:21583040`, support commit `a23bbae0a`:

| command / check | result |
|---|---|
| `./msc test tools/smith/gen.ms` | 311/311 tests, 17 files |
| CLI `run 1 3`, default full families | 3 clean, 0 finding, 0 timeout/unjudged; c/orc/danger/js/esm |
| CLI `run 101 2 --swarm --plant=backend` | 2 planted wrong-code bundles, canonical split `c orc danger \| js esm` |
| `rerun` of both planted bundles | 2/2 REPRODUCED; byte-identical program and every lane output |
| slice 1 CLI vs slice 2 `gen <seed> --features=fams=none`, seeds 1,2,3,7,21,24 | byte-identical after removing only ` fams=none` from the new header |

The planted seed 101 drew `fams=closure`; seed 102 drew `fams=union,generic`.
Old slice 1 bundles keep their evidence but become VOID under the new generator
identity/header; they are not migrated or deleted.
Not yet measured here: the 100-seed swarm campaign, closure-only campaign, SAN,
Raiser, Windows or Linux. The matrix above does not claim yield or exhaustive
family coverage.

## Open questions (design-level, decide before the slice that needs them)

- Canonical print vs digest as the lane-comparison surface: decided for slice 1
  by the corpus contract — canonical print, byte-compared by the runner; the
  bundle stores every lane's `out.log`, no digest.
- How the generator samples DRC-relevant lifetime shapes without becoming a
  second analyzer: start structural (capture graphs, deterministic drop
  order), measure divergence yield, add machinery only on evidence.

## Done when (arc)

- A bundle reruns byte-identically from its metadata alone.
- At least one planted divergence AND one real divergence have gone the full
  loop: detected → bundled → reduced → graduated into `src/test/corpus/`.
