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
| H2 | string/character/UTF-8 operations, templates and escaping, regex literals | P on specified byte/index space, S for owned values; R1/R8 | Strings only incidental to union helpers/prints; standalone family absent. |
| H3 | arithmetic/comparison/bitwise/logical/ternary; all compound/update forms; nullish/optional access and operator overloads | P, explicit legal effect order; R4/R6/R7 | Scalar subset source-present, many operators absent. |
| H4 | blocks, if/match, bounded for/while/do, for-of/in, break/continue, early return, unreachable and switch spelling | P/S, explicit fuel; R4/R5 | if, for, scalar match, loop exits and return subset source-present. |
| H5 | routines and function values: inference/annotations, arrows/nested declarations, defaults/rest/overloads, finite recursion | P/S, depth/work fuel and exact captures; R4/R6 | Acyclic numeric functions and closure subset source-present. |
| H6 | struct/interface/class values, fields/methods/static init/constructors, inheritance, visibility, object spread and alias/value-copy meaning | P/S; R1/R7, managed ownership not C pointer assumptions | Generic Box class only; broader aggregate shapes absent. |
| H7 | enums/BitSet, aliases/distinct/delegation, literal and discriminated types, intersections/conditional/mapped/utility types, unknown/never | P for observable meaning, D for refusal; R1/R4 | None as independent families. |
| H8 | nullable/union narrowing and reassignment, Result/try and typed errors | P/S; R4/R5 | Scalar-or-string-or-null union subset source-present; Result absent. |
| H9 | generics: inference/explicit args, constraints, nested/recursive instances, generic structs/interfaces/classes/methods | P/S, finite instantiation fuel; R1/R4/R6 | id/twice/pick/Box subset source-present. |
| H10 | dynamic/fixed arrays, Vec/Span, tuples, Map/Set/Record; iteration/destructuring/default/rest/spread/index bounds | P/S, ownership and backing lifetimes; R5/R7 | Small generic arrays/closure arrays incidental; independent collections absent. |
| H11 | conversions/coercions, extension/static/ref receivers, convention protocols, user operators | P/S or D, explicit width/type axis; R1/R7 | Numeric conversion helpers only. |
| H12 | move/ref/out/readonly/borrow/cursor, custom lifecycle hooks; field/element sinks, cleanup after branch/loop/escape | P/S, lifetime/provenance facts; R5/R6/R7 | Scalar capture/maker/loop-closure shapes source-present; owning aggregate lifecycle absent. |
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

**Still open:** scalar expression/helper costs, callback/closure invocation
weights (including repeated generic callbacks), safe budget composition through
capture graphs, and observation coverage. Source fuel and these small consumer
probes do NOT prove a whole-program execution bound or full family coverage.
The mixed-family C build needs a longer isolated deadline after the heavy gate;
it must not be called a bug or silently omitted. The 100-seed execution campaign,
closure-only campaign, driver controls, SAN and reducer remain unrun/unimplemented
at this checkpoint. Old bundles keep their source/identity; they are not rewritten
for the changed generator.

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
