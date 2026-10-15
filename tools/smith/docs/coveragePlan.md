# Smith coverage — audit and proposed expansion

Status: **matrix and four tooling mechanisms approved**, 2026-10-07, by user
resume after the explicit proposal. Implementation is in progress, not complete.
The confirmed goal extends DESIGN's four slices to the whole language surface,
in separate domains. Compiler findings are evidence to retain and park, not
compiler work in this goal.

This is not a claim that all these constructs work on the current compiler, nor
that Smith covers them. `source-present` means the generator path was read;
`probe` means the particular command below ran. A family becomes `verified` only
with its variants and consumer/oracle evidence. `compiler-blocked` requires a
repro, real output/build, an inbox pointer and an explicit reopen condition.
Nothing is compiler-blocked merely because a language doc says TODO or DONE.

## Evidence and reference anchors

Audit source tree: `4541bfd8e6245e3e0950b07f80b834a2e700e584` (`wt/smith`).
Read `tools/smith/{rng,features,gen,drive,main}.ms`, DESIGN and CSMITH-STUDY;
compared the committed generator with the retained slice-2 WIP. The prior land's
log reports suite **4243/4243**, tests **65 red / 65 known / 0 new**, corpus
**10 red / 10 known / 0 new**. That gate predates the three slice-2 commits;
it is not a gate verdict for the expansion.

Reference checkout read directly at `0cdc710315cfee9035e22ef4363ca479270d1934`.
Its machine-local path belongs on the arc card. Anchors below are relative to
that checkout, not this repo:

| key | reference mechanism read | implication for Smith |
|---|---|---|
| R1 | `src/DefaultProgramGenerator.cpp:67` `goGenerator`; `src/OutputMgr.cpp:235` `OutputHeader` | Typed generation and seed/full config identity, not token soup. |
| R2 | `src/DefaultRndNumGenerator.cpp:98` `rnd_upto` | Rejected draws consume the RNG stream; exact options/version matter. |
| R3 | `scripts/compare_csmith_outputs.py:165` `make_swarm_args` | One random density per configuration, then independent choices at that density. |
| R4 | `src/Statement.cpp:242` `make_random` | Context filters and post-generation analysis; the retry itself is not a hard termination proof. |
| R5 | `src/Block.cpp:513` `find_fixed_point`, `:682` `post_creation_analysis` | Join/back-edge facts; reject unsafe tails and restore consistent state. The reference iteration assert is not a bound to copy blindly. |
| R6 | `src/FunctionInvocationUser.cpp:173` `build_invocation_and_function` | Arguments' effects precede body generation; calls transfer facts/effects. |
| R7 | `src/Effect.cpp:480` `has_race_with`; `src/FactPointTo.cpp:411` `is_valid_ptr` | Conflicting effects and any maybe-null/dead target are safety obligations. This is C expression safety, not a concurrency scheduler. |
| R8 | `driver/run_program` `parse_output` and its exit/timeout handling | Distinguish missing observation, crash and timeout from agreement. Keep Smith's corpus byte oracle, not the reference checksum. |
| R9 | CSMITH-STUDY §Reduction, §Broken corners | Pin the failure axis; do not depend on a single reducer pass, dead flags or unchecked exhaustive-generation retries. These are prior measurements, not remeasured here. |

Csmith does not supply mechanisms for MetaScript macros, managed lifecycle,
actors, compiler-diagnostic contracts or executing SBF/wasm/HCR workloads. R5-R7
inform safety but do not justify inventing an oracle for those domains.

The surface inventory was extracted from `std/meta/node.ms` `NodeKind` /
`TypeKind` and `std/meta/token.ms` `TokenKind`: **91 / 51 / 169** members.
Raw inventory is `out/smith/audit/inventory.json`. This counts enums, not language
features: contextual modifiers, protocols, erased forms and CLI modes also need
rows. Consult `docs/LANG.md`, `LANG-JSX.md`, `LANG-METAPROGRAMMING.md`,
`LANG-CONCURRENCE.md`, `LANG-MOVE.md`, `LANG-MORPH.md`, `LANG-RAW.md`, and
`BARE.md` for the surface; their old status labels are not runtime evidence.
Internal nodes/types (hidden address/deref/conversions, splices, pending/inferred
states) are reached through author syntax, never emitted as random source tokens.

## Current small probes, not a campaign

macOS arm64; installed builder `v0.3.2`, binary/support BUILD `8506eaf03`;
subject `./msc v0.3.2`, SHA-256
`83b751d08c5708a832f1a67d4609c7ec39efc6fdc73f3350d88d0abb524e778d`.

Commands, from the worktree root:

```sh
msc build tools/smith/main.ms --output=out/smith/audit/cli
out/smith/audit/cli gen 1 --swarm > out/smith/audit/seed1.ms
./msc check out/smith/audit/seed1.ms
python3 out/smith/audit/probe.py
```

The retained probe calls `gen` twice for seeds **1,2,3,7,21,24** with each of
`fams=none`, `closure`, `union`, `generic`, and `closure,union,generic`, comparing
source bytes; it also generates seeds 1..100 with `--swarm` and counts vectors.
Build output: `Built 14 module(s)`; seed-1 check: `OK no type errors in 48
module(s)`. **30/30 repeat pairs byte-identical**. The 100 generations drew
**98 distinct vectors**, all eight family subsets:

| subset | seeds |
|---|---:|
| none | 12 |
| closure | 10 |
| union | 13 |
| generic | 14 |
| closure,union | 14 |
| closure,generic | 14 |
| union,generic | 11 |
| closure,union,generic | 12 |

These are generation counts, not execution coverage. No runtime parity, SAN,
Raiser, target execution, statistical distribution proof, large-vector bounds or
reducer was run by this probe. A shared heavy gate was active, so the 100-seed
lane campaign was not started beside it. Earlier slice-2 parity/rerun evidence
remains in DESIGN §Slice 2 — measured.

## Approved coverage/domain matrix

`P` = existing corpus parity, with exact deterministic stdout and selected lanes.
`S` = existing corpus SAN/DRC ledger. `I` = generated invariant checked before a
stable canonical summary, plus a separately generated sequential/reference
result where applicable. `D` = a pinned compile diagnostic, not lane agreement.
`T` = target/reload execution through an existing consumer, not compile success.
P/S and the I/D/T tooling extensions below are approved; no new runner is
assumed. Each row must later link runnable variants and its verified/blocked
state. A single syntax hit does not verify a row.

| id | surface / safety axis to vary | proposed oracle / reference | present Smith state |
|---|---|---|---|
| H1 | sized integers, float64; add float32, char, bigint, boolean/null/void; spelling and width edges | P; R1/R2 + DESIGN numeric guards | Arithmetic types source-present; additional types not implemented. |
| H2 | string/character/UTF-8 operations, templates and escaping, regex literals | P on specified byte/index space, S for owned values; R1/R8 | `str` family (§Collection, string and ownership families); never astral text. Surface measured (§Surfaces measured). |
| H3 | arithmetic/comparison/bitwise/logical/ternary; all compound/update forms; nullish/optional access and operator overloads | P, explicit legal effect order; R4/R6/R7 | Scalar subset source-present, many operators absent. |
| H4 | blocks, if/match, bounded for/while/do, for-of/in, break/continue, early return, unreachable and switch spelling | P/S, explicit fuel; R4/R5 | if, for, scalar match, loop exits and return subset source-present. |
| H5 | routines and function values: inference/annotations, arrows/nested declarations, defaults/rest/overloads, finite recursion | P/S, depth/work fuel and exact captures; R4/R6 | Acyclic numeric functions and closure subset source-present. |
| H6 | struct/interface/class values, fields/methods/static init/constructors, inheritance, visibility, object spread and alias/value-copy meaning | P/S; R1/R7, managed ownership not C pointer assumptions | Generic Box class, plus the `agg` family (§Aggregate family): nested struct copies, `ref`, spread, `==`, class aliases. Inheritance, statics, interfaces absent. |
| H7 | enums/BitSet, aliases/distinct/delegation, literal and discriminated types, intersections/conditional/mapped/utility types, unknown/never | P for observable meaning, D for refusal; R1/R4 | None as independent families. |
| H8 | nullable/union narrowing and reassignment, Result/try and typed errors | P/S; R4/R5 | Scalar-or-string-or-null union subset source-present; Result absent. |
| H9 | generics: inference/explicit args, constraints, nested/recursive instances, generic structs/interfaces/classes/methods | P/S, finite instantiation fuel; R1/R4/R6 | id/twice/pick/Box subset source-present. |
| H10 | dynamic/fixed arrays, Vec/Span, tuples, Map/Set/Record; iteration/destructuring/default/rest/spread/index bounds | P/S, ownership and backing lifetimes; R5/R7 | `coll` family (§Collection, string and ownership families): arrays, `Map`, `Set`, fixed arrays, one-level destructuring. `Vec` / `Span` / `Record`, tuples and nested destructuring absent. Surface measured (§Surfaces measured). |
| H11 | conversions/coercions, extension/static/ref receivers, convention protocols, user operators | P/S or D, explicit width/type axis; R1/R7 | Numeric conversion helpers only. |
| H12 | move/ref/out/readonly/borrow/cursor, custom lifecycle hooks; field/element sinks, cleanup after branch/loop/escape | P/S, lifetime/provenance facts; R5/R6/R7 | `own` family (§Collection, string and ownership families): hooked struct, copy, `move`, `ref` / `out`, array sinks; judged on parity and SAN, the SAN lane with no planted failure. Surface measured: hooks are not a parity oracle (§Surfaces measured). |
| H13 | throw/catch/finally/defer, typed throw vs Result, unwinding of partially built values | P/S and D where required; R4/R5 | Not implemented. |
| H14 | generators/yield/delegation, iterators, nested routines across resume | P/S on supporting lanes; bounded resumes; R4/R5/R6 | Not implemented; Raiser capability must be probed, not presumed. |
| H15 | modules/import/export/re-export/alias/cycle and backend-specific module selection | P/S with complete project bundle; R1/R6 | Single-file source only. |
| B1 | when/flags/traits; inline/noinline and build modes; self-hosting sizeof | P on common observable meaning, D for illegal forms; R1/R8 | when only in planted tests; trait/annotation families absent. |
| C1 | async/await/Promise/typed async Result; owned values across suspension and failure | P/S when deterministic; I for task invariants; R5/R6/R7 is safety guidance only | Not implemented. |
| C2 | spawn/join, move/Readonly/Arc/Locked, affine scope rules, parallel effects | Native P/S + I + D; bound tasks and work, no worker-order prints | Not implemented. |
| C3 | actors, SEND/CALL/state isolation, per-sender order, shutdown/drain and orphan errors | Native P/S + I + D; use logical IDs and final state, not arrival order | Not implemented. |
| C4 | cancellation, rejection, racing promises and timeout fusion | I/D; bounded logical outcomes, no timers in the parity program | Not implemented; do not treat different legal winners as wrong code. |
| M1 | comptime blocks/functions, macros/quotes/splices, converters and decorators, compile-time reflection/symbol binding | P/S for expanded consumer vs plain equivalent, D for invalid boundaries; R1/R6 | Not implemented. |
| M2 | JSX elements/fragments/text/attributes/spreads consumed by a macro | P via a deterministic test macro and plain equivalent, D for illegal runtime Node escape | Not implemented; no UI/browser dependency needed. |
| N1 | Ptr/Ref/Borrow/cursor/cstring, sizeof/extern/header import, ref/out/sink ABI and callback ownership | Native P/S + I/D, live owned backing and explicit provenance; R5/R7 | Not implemented. Managed safety alone does not cover raw pointers. |
| N2 | include/compile/link/passC/passL/raw emit and extern classes/constants; native/backend modules | Existing native-build consumers + T/D; generated fixtures and dependency identity | Not implemented; arbitrary host memory or libraries are not random inputs. |
| Q1 | test/assert, positive/negative checker contracts, declaration placement and contextual keywords | Existing language/guard idioms + D; expected diagnostic identity | Not implemented. Compiler rejection of arbitrary invalid source is not an oracle. |
| T1 | manual/bare, emcc/wasm and SBF/Solana; ABI/entry/allocator/target restrictions | T/D, native model or target invariant; reuse existing target tooling | Not implemented; compile-only acceptance cannot verify execution. |
| T2 | HCR init/reload/state lifecycle and module images | Existing `src/test/hcr/run.ms` consumer + T/S where available | Not implemented; cold-run vs reload-run final result, not timing. |
| T3 | macOS/Windows/Linux and C compiler/toolchain capability axes | Same P/S contracts in those environments, explicit unavailable state | Only macOS generation probe here; no cross-platform claim. |

Std APIs are exercised only as carriers of language semantics in these rows;
this goal does not become a random filesystem/network/crypto API exerciser.
Reserved/internal/legacy syntax still gets a positive or negative boundary probe,
not silently dropped from the inventory. Erlang is postponed by the repo; it is
an explicit target decision to record, not an invented working backend.

## Audit gaps before hardening

Snapshot at the audit source tree above, not current implementation status.
The measured hardening below supersedes some of these source-review findings:

- `features.ms` `swarm` uses a fixed 50% per type/family rather than R3's random
  per-configuration density. Recommend the reference density model; record the
  generator identity change, rather than migrating old evidence silently.
- Committed inline checks: gen **2**, features **8**, rng **3**, driver/CLI **0**.
  Four additional generator checks are still only in slice-2 WIP. Restore them as
  verified regression checks, then add negative controls at driver boundaries.
- `gen.ms` `convert` redraws until its source type differs; depth/trips/call cost
  are not a proof of a bounded RNG retry. Closure/generic invocation cost and
  observation coverage need a measured budget audit, not just numeric-function
  call caps. Valid feature extremes must not overflow accounting or explode work.
- `drive.ms` `runCorpus` forces SAN off; SAN has no bundle classification yet.
  `rerunBundle` checks regenerated source and compiler bytes, but needs controls
  for lost lanes, changed support/fixtures, missing or malformed metadata, and
  exact symptom preservation. Git provenance is not a content manifest.
- Sandbox/bundle preparation removes existing paths; before campaigns/reduction,
  prove reruns do not clobber evidence and partial/failed runs cannot read stale
  cells. A bundle needs immutable identity, not a filename that a rerun overwrites.
- No reducer or graduation command exists yet. The current pins demonstrate real
  compiler discoveries, not automated reduction; keep that distinction.

## Core hardening — measured

2026-10-07, macOS arm64 on the shared machine with a foreign gate active.
Final source tree `a038fee4504bca2eea314dad30db645efb21cbc7`; subject compiler
SHA-256 remains the one recorded above. No compiler/runtime/std was changed.

| check | result |
|---|---|
| Density guards, fixed-coin source, C / JS | Both tests red on each backend; a shared density makes them green. |
| `msc test tools/smith/gen.ms` / `msc test tools/smith/gen.ms --target=js` on final source | **322/322 C**, **85/85 JS**, 0 red. |
| Four restored generator guards, independently mutated header / plant / disabled-family / enabled-family behavior, C and JS | **8/8 controls red**, each on exactly its intended guard. |
| 20,000 seeds (0..19999), default three-family swarm, C == JS | All families **4959**, none **5019** (reference model probabilities 1/4 each). |
| Same seeds, `types=uint64 fams=closure,union`, C == JS | Both families **6684** (reference model probability 1/3). |
| Before node fuel, seed 1, `fams=none funcs=1 globals=1 stmts=32 depth=4 expr=1 trips=64 entries=1` | **3,612,592 bytes**, 0.578 s; source-size guard red on C and JS. |
| Weighted block-exhaustion and per-loop call-overhead guards on old accounting, C and JS | Both red on each backend; final accounting makes them green. |
| Max legal numeric knobs, six seeds × three family vectors (below), final generator | **18/18 generated**, max **64,448 bytes**, max **0.509 s**; timing is not an idle-machine performance claim. |
| Seed 1 of each extreme vector, `./msc check <generated.ms>` | **3/3 clean**. |
| Same seed, compiled C/JS consumers, `fams=none` and `fams=closure` | **4/4 run exit 0**, exact stdout equality for both pairs. |
| Same seed, all-family consumer | JS build/run exit 0; C build exceeded **30 s**. Not a compiler finding until a longer deadline and isolation resolve it. |

The extreme sweep uses seeds **1,2,3,7,21,24**, each of `fams=none`, `closure`,
and `closure,union,generic`, with `funcs=64 globals=64 stmts=32 depth=8 expr=8
trips=64 entries=64`. Final CLI regeneration was byte-identical to all three
measured consumer inputs; the last source edit only changed an equivalent block
loop spelling and strengthened an inline scope assertion.

Reproduction commands: `msc build tools/smith/main.ms
--output=out/smith/core/cli-final`, then `gen <seed> --features="<vector above>"`.
Build consumers with `./msc build <file> --target=c|js --output=<artifact>` and
execute the C artifact / `node <artifact.js>`, keeping stdout separate from build
logs. Density probe: call `Features.defaults().swarm(seed)` for 0..19999, count
full/empty family masks; repeat with the restricted vector above.
Raw matrices/logs/controls are under `out/smith/core/`, not committed.

Mechanism pointers: `features.ms` `swarm` follows R3 using a uniform uint64
threshold, rather than a fixed coin. `gen.ms` `Gen.nodesLeft`, `Gen.reserve`,
`Gen.block`, `Gen.statement`, `Gen.call` and `Gen.convert` bound source creation,
weighted numeric blocks/loops/calls and selection retries using the existing
budget model. No compiler pass or runtime protocol was added.

### Execution work bound — measured 2026-10-08

Every node the generator emits is now charged to the existing `Gen.reserve` budget:
expression and condition nodes cost 1, and a closure body is built in its own
`Gen.routine` frame. A deferred body (named callable, effect, closure array, maker)
records its cost on its `Ent`, the same way `Fn.cost` does. A call site reserves
`cost + 1` under the loop multiplier, or falls back. An immediate invocation (IIFE,
`twiceG` ×2, `BoxG.map`) takes its body cap from `Gen.spare` and pays `times × cost`.
Closure bodies may now call `fN` routines; the old `costCap = cost` block is gone. The
one uncharged repeat is the closure-array fill loop, at most 4 pushes per execution.

| check | result |
|---|---|
| `msc test tools/smith/gen.ms`, C / `--target=js`, `./msc` SHA-256 `a71ac39a…` | **326/326**, **89/89**, 0 red |
| Five mutants (expression free, named call free, `twiceG` charged once, IIFE body free, deferred frame cap 0), C and JS | **10/10 red**, each only on its own guard |
| 200 seeds × default knobs, total source bytes before → after | none 2,538,556 → 2,516,991; closure 2,909,506 → 2,822,925; all three 3,450,493 → 3,561,067 |
| Closure bodies that open with an `fN(` call, same sweep | closure 0 → 196; all three 0 → 95 |
| Seeds 1,2,3 × `fams=none` / `closure` / `closure,union,generic`, `funcs=64 globals=64 stmts=32 depth=8 expr=8 trips=64 entries=64`, `./msc` | 9/9 generated (48–64 KB); every run that built finished in ≤ **0.60 s** C and ≤ **0.06 s** JS; the 6 seeds that built and ran on both lanes printed identical stdout |

The run times come from the shared machine at load 16–60. They show that the extreme
vectors finish quickly, not how fast an idle machine runs them.

The same sweep found three compiler failures on valid programs, reproduced with the
installed `msc` (BUILD `c0949e9f2`, SHA-256 `1362b92c…`) outside the worktree:

- `none-1`: C runs; JS throws `SyntaxError: Invalid left-hand side expression in prefix operation`.
- `closure-3`: JS runs; C fails with `use of undeclared identifier '_envP'`.
- `closure_union_generic-2`: JS runs; C fails with `use of undeclared identifier 'dollarhoist_6_'`.

No inbox card covers them. Their inputs and logs are kept in `out/smith/budget/findings/`
as real-divergence inputs for the reducer. They are reduced and filed when the reducer
exists, or earlier if the person asks. The 2026-10-07 mixed-family input
(`out/smith/core/work-extreme-closure_union_generic.ms`), whose C build exceeded 30 s,
built with the same `./msc` in **4 s** at load 7 on 2026-10-08, ran with exit 0, and
printed stdout byte-identical to its JS run. The timeout came from the loaded machine,
not from the compiler.

**Still open:** observation coverage (locals and closure state that never reach the
output). The two campaigns are in §G0 campaigns below. Old bundles keep their
source and identity; they are not rewritten for the changed generator.

### Per-construct weights (G3, first half) — measured 2026-10-08

`Features.w` holds 34 `w.<group>.<name>=0..100` weights: `w.expr.{leaf,binary,unary,
convert,ternary,call}`, `w.stmt.{let,assign,compound,if,for,match,break,return}`,
`w.fam.{closure,union,generic}`, `w.closure.{named,array,iife,decl,effect,invoke,maker,fill}`,
`w.generic.{id,twice,pick,map,box}` and the percentages `w.expr.fam`, `w.stmt.fam`,
`w.stmt.else`, `w.union.len`. A group may not be all zero. `format` prints only
non-default weights, so every old header and bundle parses unchanged. Kind groups draw
`below(sum)`, which at the defaults is `below(100)` / `below(3)` / `below(6)` as before.
Source tree `7c55bccb7decbcac72337f174dbfc16355888f4d`; installed `msc`
(`~/.metascript/BUILD` `525c8ba4f`).

| check | result |
|---|---|
| `gen <seed>` of the base (`8894ce287`) and this tree, seeds 1..200, `cmp`: default / `fams=none` / `fams=closure` / `--swarm` / `fams=union types=int32,uint8` / `fams=generic stmts=8 depth=4 expr=4` / `plant=backend` | **200/200** identical for each of the 7 vectors, header line included |
| `msc test tools/smith/gen.ms`, C / `--target=js` | **341/341**, **104/104** (base 326 / 89) |
| 10 mutants (weights ignored, `format` printing all / none, `g.w` not set, iife guard, two binary-fallback guards, compound guard, family weights ignored, all-zero group accepted), C and JS | **10/10 red**, each on 1–3 intended guards, no collateral |
| Aimed batches, seeds 1..200; hit = target marker count strictly exceeds each other marker count in the program body (markers: ` ? `, `fN(` calls, `(qN:` lambdas, convert, unary, binary spellings by regex) | below |
| `msc check` of seeds 1..20 of each aimed vector | **20/20 clean** for all three |

| aimed vector (on top of base) | dominant | same, no weights | count: base → aimed (mean per program) |
|---|---|---|---|
| ternary: `fams=none` + `w.expr.ternary=80 leaf=10 binary=4 unary=2 convert=2 call=2` | **200/200** | 0/200 | 26 → 355 |
| call: `fams=none types=int32 funcs=16 expr=2 stmts=2` + `w.expr.call=80 leaf=10 binary=4 unary=2 convert=2 ternary=2 w.stmt.let=60 assign=20 if=5 for=5 compound=4 match=2 break=2 return=2` | **191/200** | 0/200 | 29 → 64 |
| closure: `fams=closure` + `w.expr.fam=90 w.stmt.fam=60 w.closure.iife=4` | **200/200** | 0/200 | 65 → 267 |

Not measured: with `w.expr.call` alone and the default type set, calls stay at
**0/200** dominant (mean 14 → 28): the cost bound refuses a call whose callee is
expensive, and a call needs an earlier routine of the requested type. A caller
aims calls by also narrowing `types`, `expr` and `stmts`. Markers are regex counts
of generated text, not generator decisions; negative-literal casts inflate the
convert and binary counts, which is conservative for the aimed construct. Bash
and script sources of the measurement are in `out/smith/weights/` (untracked).

### G0 campaigns — measured 2026-10-12

Generator tree `c34c8641e34a7b9bf17a4585af9e87f78f4616fe`; subject and harness the installed `msc` v0.3.2, BUILD
`ea7ae4d17` (hash `b980a820_4a4ca578:22547904`); lanes c / orc / danger / js / esm;
`MSCORPUS_JOBS=4`; macOS arm64, 14 cores, load average 6–12, no gate in
`~/.metascript/gates` from start to end (one started a minute after the second run).

```sh
MSC=~/.metascript/bin/msc MSCORPUS_JOBS=4 msc run tools/smith/main.ms run 1 100 --swarm
MSC=~/.metascript/bin/msc MSCORPUS_JOBS=4 msc run tools/smith/main.ms run 1 100 --features="fams=closure"
```

| campaign | wall | CPU (user+sys) | programs / wall hour | programs / CPU hour | clean | findings | timeout |
|---|---:|---:|---:|---:|---:|---:|---:|
| swarm, seeds 1..100 | 136 s | 465 s | 2,650 | 774 | 96 | 4 | 0 |
| `fams=closure`, seeds 1..100 | 187 s | 500 s | 1,925 | 720 | 98 | 2 | 0 |

The six findings are four compiler bugs. Each was matched by its symptom in the bundle,
not by its verdict line:

| inbox card | swarm | closure | bundle verdict |
|---|---:|---:|---|
| `2026-10-08-js-double-negation-emits-decrement` | 2 (seeds 23, 64) | 1 (seed 31) | seeds 64 and 31 crash on JS (`SyntaxError`); seed 23 is wrong-code, `(-(-g3))` emitted as `--g3` |
| `2026-10-08-ternary-hoist-lost-when-else-holds-a-nested-ternary` | 1 (seed 58) | 0 | C build fails |
| `2026-10-08-capture-free-lambda-links-child-env-to-missing-envP` | 1 (seed 80) | 0 | C build fails |
| `2026-10-12-c-compound-assignment-reads-target-after-the-right-side` (new) | 0 | 1 (seed 43) | wrong-code `c orc danger \| js esm` |

So the rate is **4 distinct bugs in 965 CPU-seconds**, about 15 per CPU hour, and one of
them new: at this size a second batch of the same vector mostly re-finds the same bugs.
One bug owns half the bundles, and the ternary-hoist bug that the 2026-10-08 extreme
vectors hit often appears in 1 of 200 default-size programs. A program that fails to
build on C or to load on JS runs nothing on that lane, so each of these four bundles
may hide a second divergence; no arm with the masking construct switched off
(`w.expr.unary=0` for the double negation) was run to measure that.

Seed 43 went through `reduce`: 11,668 → 2,970 bytes in about 8 minutes, then the run was
stopped because a gate took the machine, and the last cut to a 7-line repro was by hand
(the card holds it). Seed 23 was classified by reading the emitted JS, not reduced.

Not measured: an idle machine, `--san`, the Raiser lane, other seed ranges or batch
sizes, the masking arm above, and any vector other than these two. Bundles are under
`out/smith/bundles/` and the two run logs under `out/smith/g0/` (untracked).

### Aggregate family (G3) — measured 2026-10-12

`fams=agg` (`Fam.Agg`, `Gen.aggExpr` / `Gen.aggStatement` in `gen.ms`) adds, per scalar
type, a nested value struct, a class that holds one, and helpers that copy, spread,
compare, pass by `ref` and alias them. It is in the default family set and in the swarm
draw, with 12 new weights `w.fam.agg` and `w.agg.*` (46 in all). Struct `==` is not drawn
for `float64` fields: NaN inside a struct was not measured. Generator tree
`f520d514854c99dbc06c858f99df9c713cd2d94c`; installed `msc` BUILD `ea7ae4d17`.

| check | result |
|---|---|
| `gen <seed>` before and after, seeds 1..100, `cmp`: `fams=closure,union,generic` / `fams=none` / `fams=closure` / `fams=union types=int32,uint8` / `fams=generic stmts=8 depth=4 expr=4` / `fams=closure,union,generic plant=backend` | **600/600** identical: a vector without `agg` keeps its program |
| `msc test tools/smith/gen.ms`, C / `--target=js` | **344/344**, **107/107** |
| 3 mutants (`==` drawn for float, statement weights ignored, helpers emitted without the family) | **3/3 red**, each on its own guard |
| `msc check` of `fams=agg`, seeds 1..20 | **20/20 clean** |
| `run 1 12 --features="fams=agg"` | 12 clean |
| `run 1 40 --features="fams=agg types=int32,uint8 stmts=8 w.stmt.fam=80"`, `MSCORPUS_JOBS=2` | 161 s, 39 clean, 1 wrong-code (seed 11) |
| `run 1 40 --features="fams=closure,union,generic,agg stmts=6 w.fam.agg=3"`, `MSCORPUS_JOBS=2` | 36 clean, 4 crashes, all known: ternary hoist 3 (seeds 7, 15, 40), double negation 1 (seed 37) |

Seed 11 is a new compiler bug, not an aggregate one: a struct-valued argument is hoisted
on C and runs before an earlier operand that reads a global
(inbox `2026-10-12-c-hoisted-argument-runs-before-an-earlier-variable-read`). The batches
ran beside another session's gate (load 6–37), so their wall times are not throughput.

With the default nine types a struct variable is rarely used again: 40 default-size
`fams=agg types=int32,uint8` programs hold 4 spreads, 3 `ref` calls and no nested-struct
copy; the aimed vector above holds 29, 83 and 23. Aim with `types`, `stmts` and
`w.stmt.fam`, as for calls.

Not covered by the family: inheritance, statics, getters and setters, interfaces, structs
in arrays or closures as a drawn shape, `float64` struct equality. Not measured: SAN,
Raiser, any batch larger than 40.

### Collection, string and ownership families (G3) — measured 2026-10-15

Three families follow the `agg` idiom (an `EntKind` per value they track, a `Gen.<fam>Expr`
/ `Gen.<fam>Statement` pair, helpers emitted only when the family is drawn, a weight group
of their own): `fams=coll` (H10), `fams=str` (H2) and `fams=own` (H12). All three are in the
default family set and in the swarm draw; with them the weight table holds 82 keys. Each
emits only the shapes §Surfaces measured found raw, or guarded so that every lane computes
the same value:

- `coll`: `T[]` indexed through `ixI` (index kept in `0..length-1`) behind a non-empty
  test, `Map.get` only through `??`, `push`, `pop`, `splice`, shrinking `setLength`,
  `fill`, `reverse`, `slice`, `concat`, `indexOf` (never on `float64` elements),
  `join`, `includes`, aliasing, three loop forms with a trip bound, one-level destructuring
  with defaults and a rest, `Map` / `Set` with no write inside their own `for…of` and no
  `float64` Set, fixed `T[N]` copy and write, spread into a rest parameter.
- `str`: concatenation, `+=` and `=` with the result cut to a bounded length, templates,
  `String(x)`, `slice` / `substring` / `charAt`, case and trim, `repeat`, `padStart` /
  `padEnd`, `replace` / `replaceAll` / `split(sep).join`, `length` / `indexOf` /
  `lastIndexOf` / `charCodeAt`, `==` `!=` `<` `>` `includes` `startsWith` `endsWith`, over an
  alphabet of ASCII, BMP non-ASCII and every escape form, never astral.
- `own`: a hooked `struct Own<T>` whose `onDestroy` / `onCopy` count into a global that is
  never printed, copies, `move` only of a variable declared in the same block and never
  named again, `ref` and `out` parameters, sinks into an array, element reads; nothing of it
  inside a closure body.

Generator tree of the second batch `daabe58b9` (first batch `8a118417d`); subject and harness
the installed `msc` v0.3.3, BUILD `f82403c8e`; lanes c / orc / danger / js / esm; macOS
arm64, no gate in `~/.metascript/gates` for the second batch (the first batch overlapped a
release gate for its last run).

| check | result |
|---|---|
| `gen <seed>` with the CLI before `coll` and with `daabe58b9`, seeds 1..100: `fams=closure,union,generic,agg` / `fams=none` / `fams=closure` / `fams=union types=int32,uint8` / `fams=agg types=int32,uint8 stmts=8 w.stmt.fam=80` / `plant=backend` | **600/600** identical |
| `msc test tools/smith/gen.ms`, C / `--target=js` | **353/353**, **116/116** |
| `drive.ms` C; `identity.ms` C / JS | **438/438**; **308/308**, **71/71** |
| family statement lines, 40 programs, aimed `types=int32,uint8 stmts=8 w.stmt.fam=80` | coll 76 %, str 82 %, own 80 % |
| the same, default vector `fams=<fam>` | coll 50 %, str 49 %, own 58 % |
| `msc check`, aimed vector, seeds 1..40 per family (coll, str) | **80/80** clean |

The concentration count is a line heuristic: a statement line in a function body that is
not one of the scalar statement forms counts as a family line.

Batches (`run <first> <count> --features=…`), counted by the symptom in each bundle:

| batch | gen | programs | clean | findings, by cause |
|---|---|---:|---:|---|
| `fams=coll`, aimed | `8a118417d` | 40 | 30 | 8 `Map`/`Set` `.size` refused on JS; 2 a Smith bug (below) |
| `fams=coll`, default | `8a118417d` | 12 | 11 | 1 double negation |
| `fams=str`, aimed | `8a118417d` | 40 | 14 | 18 `padStart`/`padEnd` panic on C debug; 8 ternary hoist |
| `fams=str`, default | `8a118417d` | 12 | 3 | 7 ternary hoist; 2 pad |
| `fams=own`, aimed | `8a118417d` | 40 | 40 | — |
| `fams=own`, aimed, `--san` | `daabe58b9` | 12 | 12 | — |
| `fams=coll`, aimed | `daabe58b9` | 40 | 39 | 1 ternary hoist |
| `fams=str`, aimed | `daabe58b9` | 40 | 35 | 5 ternary hoist |
| all seven families, `stmts=6` | `daabe58b9` | 40 | 26 | 12 ternary hoist; 1 double negation; 1 both |
| `--swarm`, `MSCORPUS_JOBS=4` | `daabe58b9` | 100 | 91 | 5 ternary hoist; 2 double negation; 1 `_envP`; 1 hoisted argument |
| `--swarm --features="w.expr.unary=0"`, `MSCORPUS_JOBS=4` | `daabe58b9` | 100 | 91 | 7 ternary hoist; 1 compound assignment; 1 hoisted argument |
| `fams=coll`, aimed | `bf9abc145` | 40 | 40 | — |
| `fams=str`, aimed | `bf9abc145` | 40 | 38 | 2 ternary hoist |
| all seven families, `stmts=6` | `c7c28bb56` | 40 | 30 | 7 ternary hoist (one with a second C error); 3 double negation |
| `--swarm`, `MSCORPUS_JOBS=4` | `c7c28bb56` | 100 | 94 | 3 ternary hoist; 2 double negation; 1 `_envP` |
| `--swarm --features="w.expr.unary=0"`, `MSCORPUS_JOBS=4` | `c7c28bb56` | 100 | 93 | 5 ternary hoist; 1 compound assignment; 1 hoisted argument |

The Smith bug: a family result that is a ternary with literal arms was cast to a narrower
type with a raw `as`, and the checker folds that cast and refuses the literal. `convert`
now treats a family ternary as checked at compile time (`Gen.ternary`); the guard test
"a family ternary is never narrowed by a raw cast" fails on the generator without it.

Two compiler bugs found by these families are parked in the generator, because each
buried every other finding of the program it hit: `.size` is not drawn (inbox
`2026-10-15-map-and-set-size-is-int32-on-c-and-number-on-js`), and `pad` pads only a
receiver with a non-empty literal appended (inbox
`2026-10-15-c-padstart-padend-panic-on-an-empty-string-with-no-payload`). A destructured
rest is bound and never used (inbox
`2026-10-15-array-destructuring-rest-is-typed-vec-not-the-source-array-type`).

Masking. The swarm pair runs the same generator with and without `w.expr.unary`, over
different programs per seed, so it compares rates, not pairs. Switching the double
negation off removed its 2 findings and found 1 compound-assignment and 1 hoisted-argument
program. Both are known cards; the hoisted-argument programs of the two arms are new
triggers of that card, a rest-parameter call (mask seed 34) and a ternary argument
(control seed 28, reduced 17,133 → 340 bytes in the 1,200 s cap), each cut by hand and
recorded there. Mask seed 14 was matched to the compound-assignment card by reading: the
callee on the right side of `g4 +=` writes `g4`. At 100 programs neither arm shows the double negation
hiding a bug. The ternary-hoist bug is now the larger mask: it fails the C build of 5–7 %
of swarm programs and of 13 of 40 programs that draw all seven families, so those programs
judge nothing on C.
`bf9abc145` parks the shape the card records: inside the else arm of any ternary, an
arithmetic operand never holds a ternary (`Gen.elseExpr`, `arithInElse`). It changed 83 of
the 600 programs of the identity vectors, and exactly those 83 are the ones where the park
fired (a probe build that logs each firing). Hoist failures fell from 12 to 7 in the
seven-family batch, from 5 to 3 in swarm and from 7 to 5 in the mask arm (`bf9abc145` and
`c7c28bb56` generate the same programs; the later commits touch only the plant, the driver
and the reducer), so the bug has a second shape the park does not cover. Smith's reducer found one
(mask seed 12, recorded on the card): a `new` temporary inside a call argument of the
then-branch and a nested ternary inside a call of the else-branch, with no arithmetic. A
wider park, no ternary anywhere below an else arm, changed 137 of the 600 identity programs
and left 2, 6, 3 and 4 hoist failures in the same four batches, so it was reverted: it cost
far more coverage than it removed, and the remaining failures stay findings for the card.
Smith's reducer cut one string-family hoist bundle 6,144 → 152 bytes to the shape the card
already records: string temporaries in the condition, arithmetic on a nested ternary in the
else-branch.

The SAN lane caught its plant after these batches (`DESIGN.md`, planted SAN loop), so the
lane and the driver work; `own`'s 12 clean SAN programs still say nothing about how often
a lifecycle bug would trip it. Not measured: the Raiser
lane; CPU time of these batches; batches larger than 100; `Vec` / `Span` / `Record`,
nested destructuring, astral text, `onMove` / `onMoved` hooks, `move` into a constructor.

### Surfaces measured for the next families — 2026-10-12

Four probe sets, one per family, each run on C debug, C `--danger --cc=clang` and JS
(node 24.1.0) with the installed `msc` BUILD `ea7ae4d17`; the ownership set also on
`--gc=orc`. Probes and per-lane outputs are under `out/smith/g3/{h6,h10,h2,h12}/`
(untracked). Every finding below was run again by hand before its card was written.
"Raw" means byte-identical output on every lane measured.

**H6 struct / class.** Raw: field read and write to three nesting levels over all nine
scalar types; struct copy on assignment, argument, return, array element, class field and
`slice`; `ref` / `out` / `readonly` struct parameters of free functions; spread; struct
`==` (structural, also nested and with string fields); class and interface aliasing and
identity `==`; constructors, field initializers, statics, single and multi-level
inheritance with override and `super(…)`, getters and setters, visibility, `instanceof`.
Refused by the checker, so never emitted: a write through a by-value struct parameter, a
`for…of` variable or a `const` struct; a `const` passed to `ref`; methods or defaults in a
`struct`.

| never emit until fixed | split | inbox |
|---|---|---|
| `super.m()` | fails on every lane | `2026-10-07-super-method-call-fails-on-c-and-js` |
| `ref` parameter on a class method | C runs, JS `SyntaxError` | `2026-10-12-js-ref-parameter-on-a-class-method-emits-invalid-js` |
| overridable method called from a base constructor | C reads 0, JS `TypeError` | `2026-10-12-base-constructor-virtual-call-reads-subclass-field-differently-on-js` |
| `this.x = …` before `super()` | C keeps the initializer, JS `ReferenceError` | `2026-10-12-this-before-super-passes-the-checker` |

**H10 collections.** Raw: `T[]` literal, `push`, in-range index, `length`, both loop
forms, `slice`, `concat`, `indexOf`, `includes` (no NaN), `reverse`, `map`, `join(sep)`,
`splice`, `fill`, shrinking `setLength`; aliasing on assignment, argument, capture and
return; arrays of arrays; `Map` and `Set` with string, integer and float keys including
insertion order after deletes and a rehash at 60 keys; tuples and `T[N]` as values;
one-level destructuring with defaults and rest; spread into literals and rest parameters.
Needs a guard, because the lanes differ only on the erroneous input: an index outside
`0..length-1` (debug and JS throw, danger continues or segfaults), `pop` / `shift` / `at`
on an empty or short array, a destructuring pattern longer than the array, a length
change during the array's own `for…of`. Absent from the std, so refused: `filter`,
`reduce`, `sort`, `find`, `some`, `every`, `forEach`, `unshift`, `map` with an index.

| never emit until fixed | split | inbox |
|---|---|---|
| member access on `Map.get` or any `P \| null` / `T[] \| null` without a null check | checker accepts; debug panics, danger segfaults | `2026-10-12-member-access-on-nullable-class-or-array-passes-the-checker` |
| growing `setLength` | C zero-fills, JS `undefined` | `2026-10-12-js-array-setlength-grow-leaves-undefined-slots` |
| `"text" + collection` | C `<object>`, JS contents | `2026-10-12-string-concat-of-a-collection-prints-object-on-c-and-contents-on-js` |
| `includes(NaN)` | C false, JS true | `2026-10-12-array-includes-nan-is-false-on-c-and-true-on-js` |
| writing a Map or Set inside its own `for…of` | C live table, JS snapshot | `2026-10-12-mutating-a-map-or-set-during-for-of-differs-between-c-and-js` |
| nested destructuring, elided slot | refused / internal warning | `2026-10-12-nested-array-destructuring-binds-no-inner-names` |

**H2 strings.** Raw, for ASCII and for BMP non-ASCII text: `+`, `+=`, templates,
`String(x)` of every numeric type and boolean, `.length` (UTF-16 units on every lane),
`s[i]` / `charAt` / `charCodeAt` in and out of range with an index of `int32` or narrower,
`slice`, `substring`, `indexOf`, `lastIndexOf`, `includes`, `startsWith`, `endsWith`,
`split` with a non-empty separator, `join`, `trim*`, `toUpperCase` / `toLowerCase`
(ASCII letters only, on every lane), `repeat`, `padStart` / `padEnd`, `replace`,
`replaceAll`, `==`, `<` `>`, every escape form, string keys in `Map` / `Set`, parsing of
plain decimal text.

| never emit until fixed | split | inbox |
|---|---|---|
| `s[i]` with an `int64`, `uint64` or `number` index | JS `TypeError` | `2026-10-12-js-string-index-with-an-int64-or-number-index-throws` |
| `<` `>` or `sort` when a string may hold an astral character | C code-point order, JS UTF-16 order | `2026-10-12-string-ordering-differs-for-astral-against-high-bmp` |
| `split("")`, `reverse()` on non-ASCII text | bytes, different on each backend | `2026-10-12-string-split-empty-and-reverse-work-on-bytes-for-non-ascii` |
| `parseInt` / `parseFloat` / `Number` of text that is not a plain decimal in range | different values | `2026-10-12-number-parsing-of-non-decimal-text-differs-between-c-and-js` |
| cutting or printing half of an astral character | different bytes | `2026-09-27-surrogate-concat-roundtrip` |

**H12 ownership and lifecycle.** User hooks (`onDestroy`, `onCopy`, `onMove`, `onMoved`)
run on C only; on JS no hook runs and every hook counter stays 0. So neither a print from
a hook nor a count kept by one is a parity oracle: this family is judged by the SAN lane
alone, and its programs must keep hook effects out of stdout. On C the destroy order and
the per-shape copy / move counts were identical on debug, danger and orc for about 20
shapes. Raw on every lane including JS: `ref` and `out` on scalars, strings, structs,
arrays, fields and elements of free functions; `readonly`; `f(move a)` to a plain
parameter. Use after `move` is refused by the C analyzer and accepted by `msc check` and
JS (`docs/LANG.md` says the JS backend does not check moves), so a generator never reads a
moved variable.

| never emit until fixed | split | inbox |
|---|---|---|
| one struct variable to a `ref` and a by-value parameter of the same call | JS aliases the by-value one | `2026-10-12-js-by-value-struct-argument-aliases-a-ref-argument-of-the-same-variable` |
| `new Box(move a)` | copies; the hook runs twice | `2026-10-12-move-into-a-constructor-argument-copies-and-leaves-the-source-readable` |

Not measured by any of the four sets: Raiser, SAN or leaks (one ASan build of four
ownership probes was clean), ESM, `--release`, Windows, Linux, generics over these types,
`Vec` / `Span` / `Record` / `Borrow`, `onTrace` / `onClone`, async. Each "raw" row was
varied over a second type and one nesting level, not over every type; the danger lane's
out-of-range behaviour was seen once per case, not sampled.

## Approved order and NEW MECHANISM decisions

1. Harden the existing core, then SAN and reducer, before expanding families.
   Restore WIP checks, match R3, verify budget/scope contracts and evidence paths.
   Run the required 100-seed swarm and closure-only campaigns when no heavy gate
   owns the machine. Findings are bundled, triaged and parked without compiler edits.
2. Add managed host H/B families incrementally, using P/S. Require standalone and
   mixed-family variants, width/type/arity/nesting axes, and negative controls.
3. Add domain-specific C/M/N/Q/T work only under the decisions below; a missing
   environment is reported separately from a compiler blocker. A missing oracle
   is a design question, not permission to mark a family parked and finish.

**NEW MECHANISM — tooling only, approved scope; separate missing consumer
adapters still require a concrete proposal before writing:**

- **Project/evidence manifests:** extend single-file generation/bundles to module
  trees, native fixtures and exact dependency/support/lane configuration identity.
  Reuse corpus directory entries and native-build idioms. Risk: stale dependencies,
  path traversal or evidence overwrite can manufacture a reproduction.
- **Bounded task/outcome model:** generate legal async/spawn/actor/race shapes,
  compare their final logical invariants to an independent sequential model, and
  print one canonical result only after validating it. Reuse corpus serial/drain
  contracts; no custom scheduler or output normalization. Risk: an overly weak or
  correlated model accepts a wrong result or flags a legal schedule.
- **Diagnostic contracts:** generate paired legal/refused programs and pin the
  expected diagnostic/domain/axis using existing guard/CLI check idioms. Risk:
  matching generic text or treating any rejection as success hides a new bug.
- **Target/reload routing:** bundle target inputs and use the existing native-build,
  HCR, SBF and wasm consumers where they exist. Where no reusable consumer exists,
  propose that adapter separately before implementing it. Risk: build-only green,
  missing SDK/runtime identity or unavailable hosts masquerade as execution proof.

Proposed campaign acceptance for each active row: at least two meaningful variants
per claimed axis, standalone and mixed-family execution, a planted failure that
its oracle catches, and a bounded seed sweep that reports construct hits, invalid
programs, findings and unavailable lanes. Seed counts for each new domain are
chosen from measured cell cost, not a claim that 100 arbitrary seeds prove it.
No invalid program becomes clean; generator defects must be fixed, while a measured
compiler-blocked shape gets a repro/inbox and reopen condition. No full-language
completion claim while an unimplemented row lacks an approved disposition.
