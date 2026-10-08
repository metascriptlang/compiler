# Smith — design

Status: direction approved (2026-10-03..05, in conversation); slice 1 proven
2026-10-05 and slice 2 integrated/probed 2026-10-07 (§Slice 2 — measured).
On 2026-10-08 the person approved the overall plan in §Plan: Smith as the
generator an LLM strategist aims, replacing the four-slice list. This file owns
that plan, the constraints that forced it and the measurements behind the
generator's surface. Csmith-derived evidence lives in `CSMITH-STUDY.md`. The
full-language domain/oracle matrix and four tooling mechanisms are in
`coveragePlan.md`, together with the measured core hardening; approval is not
implementation or coverage evidence. Compiler findings are retained and parked,
not fixed within this goal.

## Goal

Find `msc` bugs — wrong code across backends / GC modes / optimization,
compiler crashes, DRC ledger violations — by random differential testing:
generate deterministic MetaScript programs, run them through the existing
corpus lanes, record divergences as reproducible bundles, reduce them, and
graduate confirmed regressions into the corpus.

Smith is the weapon, not the whole system. It produces valid, terminating,
reproducible programs fast. A strategist (an agent session first, an automated
LLM loop only if it earns it) reads compiler passes, ASTs, findings and coverage,
and chooses where Smith strikes: a feature vector and construct weights per batch.

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

- Not a race for program count; see §What we take, and what we leave.
- Not a compiler for AI authors yet: the "pen" use (a strategist choosing every
  generator decision) was discussed 2026-10-08 and deferred by the person.
- Not a benchmark, not a parser fuzzer (random token soup tests nothing past
  the parser), not a std-API exerciser (the corpus owns that surface), not
  distributed.
- No vendored Csmith code — mechanisms only. The reference checkout path is
  machine-local and stays on the arc card.

## What we take, and what we leave

Csmith tests mature optimizing C compilers, where the front end is solid, bugs sit
deep in optimizers, and UB avoidance dominates the generator. `msc` is young: the
three findings of 2026-10-08 (`coveragePlan.md` §Execution work bound) were a JS
emit error and two C lowering errors, from 9 programs. Bugs here are dense and live
in transforms, emit and lifetime, so construct diversity limits Smith, not volume.

| source | take | leave |
|---|---|---|
| Csmith | seed + full vector in the program; swarm; runtime-safe arithmetic; termination budget; failure-identity predicates; per-construct probability tables (`--probability-configuration`) | digest oracle; pointer/UB fact engine; volume as the goal; its broken options (CSMITH-STUDY §Broken corners) |
| WhiteFox (Yang et al., OOPSLA 2024, DOI 10.1145/3689736) | an LLM reads a pass's source and states what input reaches it; inputs that reached it seed the next round | the LLM writing the main test programs |
| Fuzz4All (Xia et al., ICSE 2024, DOI 10.1145/3597503.3639121) | free-form LLM programs as scouts where Smith has no family yet | crash as the only oracle |
| ours | C ↔ JS ↔ raiser parity; SAN/DRC ledger as the primary lifetime oracle; inbox dedupe and corpus pins | — |

Why volume is not the goal: Fuzz4All Table 2, 24 h on GCC — Csmith 61,883 programs
99.99% valid coverage 111,668; YARPGen 255,581 / 166,614; Fuzz4All 44,324 programs
37.26% valid, coverage 198,927. The same paper cites a six-month Csmith run that
found no new GCC/Clang bug. Smith's yardstick is **distinct findings per CPU-hour**,
plus per-pass coverage and the hit rate of the targeted construct.

## Plan

Three layers. **Weapon**: generator, driver, oracle, bundle, reducer. **Eyes**: what
a batch reached (passes and branches, constructs, inbox matches; `msc dump-ast`
already exists). **Strategist**: reads pass sources, ASTs, inbox and the eyes, and
picks the next vector; scouts where Smith cannot generate yet.

| phase | work | done when |
|---|---|---|
| G0 core | driver controls (lost lane, malformed metadata, rerun cannot overwrite evidence); 100-seed swarm and closure-only campaigns | measured programs per hour and finding rate |
| G1 SAN | the driver stops forcing SAN off; leak / UAF become a bundle kind | a planted SAN divergence goes the full loop |
| G2 reducer | `creduce --not-c` + identity predicate; the 2026-10-08 findings as real inputs | one planted and one real divergence graduated into the corpus |
| G3 handle | per-construct weights and shape knobs (nesting, capture in loop, aggregate into sink) in `Features`; heap/ownership families H6, H10, H2, H12 written with them | one vector concentrates ≥ 70% of a batch on the chosen construct |
| G4 eyes | **NEW MECHANISM**: coverage-instrumented `msc`, a per-pass report per batch; findings still confirmed on a normal build | a per-pass report for `lambdaLifting`, `generatorLower`, DRC inject that reruns identically |
| G5 manual strategist | an agent session aims one pass (first: `lambdaLifting`, two of three 2026-10-08 findings) against random swarm on the same CPU budget | per-pass branch coverage and distinct findings per CPU-hour for both arms |
| G6 automated loop + scouts | **NEW MECHANISM**, only if G5's aimed arm wins: LLM proposes vector → batch → eyes → next; ≥ 30% of budget stays random swarm; a scout program that finds a bug becomes the spec of the next family | measured against G5's numbers |
| G7 matrix | remaining `coveragePlan.md` rows, ordered by where findings cluster; async/actor/macro scout first | every row verified or parked with repro, inbox and reopen condition |

Slices 1–2 are done (§Slice 1, §Slice 2). The old slice 3 is G1 and slice 4 is G2.
G4 and G6 each need their own approval when reached; approving this plan approved
the direction, not those mechanisms.

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
