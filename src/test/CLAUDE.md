# Test Suite — Standards & Progress Tracker

This is the source of truth for **how testing works in this project**. It
defines what "solid" looks like, where each kind of test lives, and tracks
which guardrails are already in place vs still missing.

When you add or modify tests, **update the progress section at the bottom**.

---

## 1. Philosophy

A self-hosted compiler at this scale (3M LOC self-compile, generic mono,
DRC, async, actor, 4 DU shapes) cannot be guarded by happy-path unit tests
alone. We borrow the multi-tier strategy used by Rust, Go, TypeScript, and
Zig:

- **Inline unit tests** close to the code (per-file `test "..." { ... }`).
- **Language tests** that exercise user-visible features end-to-end.
- **Pipeline tests** that pin specific phase contracts.
- **Regression tests** with a 1-to-1 bug-to-test mapping (`fixedbugs/`).
- **Lifecycle guards** that go red on drift from the reference memory
  model (`guard/`, §3.7).
- **Differential corpus** — the same program through independent
  executions (C vs JS backend; drc vs orc and -O0 vs --danger as they
  come online), outputs byte-compared (`differential/`, §3.6). No golden
  files: the other execution IS the expected output, so tests can't drift.
- **Self-host bootstrap** as the integration test of last resort
  (gen-0 vs gen-1 fixpoint on identical input — the definition of "solid").

What "solid" means here:

| Property | Definition |
|---|---|
| **Discoverable** | A new dev can answer "where do I add a test for X" in <30s. |
| **Reproducible** | Tests live in version control and run identically on every machine. NEVER scratch files in `/tmp/`. |
| **Locked-in** | Every shipped bug fix has a regression test. Old tests are append-only — never delete or refactor regression repros. |
| **Cross-cutting** | The hard interactions (DU + generics + RC + closures + async) have explicit tests, not implicit coverage via self-host. |
| **Fast feedback** | Inline tests run natively via `msc test <file>`. Bootstrap runs in CI. |

---

## 2. Directory Layout

```
src/test/
├── CLAUDE.md           # this file
├── helpers.ms          # compileToC / compileToJS / compileProjectToC|JS
├── index.ms            # full test suite — the single entry point (all tiers)
├── lang/               # user-visible language behavior
│   ├── basics.ms       # values, control flow primitives
│   ├── strings.ms      # string ops, escapes, concat
│   ├── types.ms        # sized ints, .code, enums, bitwise, type aliases
│   ├── match.ms        # match expressions / statements
│   ├── controlFlow.ms  # if / while / for / break / continue
│   ├── closures.ms     # capture, env, closure as value
│   ├── closuresAdv.ms  # nested closures, recursion through env
│   ├── interfaces.ms   # interface-as-reference, field access
│   ├── classes.ms      # class instances, methods, inheritance
│   ├── result.ms       # Result<T, E> + try operator + edge cases
│   ├── discrim.ms      # 4 DU shapes + generic mono + RC interaction
│   ├── trycatch.ms     # try/catch/finally + throw
│   ├── recursion.ms    # direct + mutual recursion
│   ├── advanced.ms     # FFI, std/process (gated)
│   ├── async.ms        # spawn, await, futures
│   ├── syntax.ms       # exponentiation, optional chain (gated)
│   └── multimod/       # multi-module imports
├── fixedbugs/          # regression suite — append-only
│   ├── index.ms        # entry that imports every bugNNN_*.ms
│   ├── bug001_du_structural_key_collision.ms
│   ├── bug002_ref_gi_mono_name.ms
│   └── ...
├── c/                  # E2E pipeline: source → C output
│   ├── variables.ms    # local / global / const / let
│   ├── functions.ms    # signatures, params, returns
│   ├── classes.ms      # heap allocation, vtable, ctor
│   ├── control.ms      # control-flow lowering
│   ├── strings.ms      # string ops at C level
│   ├── expressions.ms  # operator precedence, casts
│   ├── closures.ms     # lambda lifting, env structs
│   ├── result.ms       # Result lowering to tagged union
│   ├── buffer.ms       # std/buffer ops
│   └── drcLifecycle.ms # DRC injection points
├── js/                 # E2E pipeline: source → JS output
│   ├── basic.ms
│   └── result.ms
├── handoff/            # phase-handoff contracts
│   └── index.ms
├── checker3pass/       # checker 3-pass invariants (scenarios/ + stress/)
├── fmt/                # formatter round-trip tests (cases/ + roundtrip.ms)
├── std/                # std-library tests (http/)
├── paralock/           # concurrency isolation probes: actorOnly / spawnOnly /
│                       #   asyncOnly (paralock/README.md + docs/PARALOCK.md)
├── guard/              # nim-guard tier — proactive lifecycle drift guards,
│                       #   built with the DRC ledger (-DMS_DRC_LEDGER).
│                       #   Runner: guard/run.sh. Every guard must be PROVEN
│                       #   RED once before it is trusted (guard/README.md).
├── differential/       # differential corpus — programs/*.ms run through BOTH
│   ├── run.sh          #   backends (C binary vs JS-on-node); stdout must
│   └── programs/*.ms   #   match byte-for-byte. Authoring contract: §3.6.
└── native/             # NATIVE-execution tier — builds real binaries (clang),
    ├── README.md       #   runs under --gc=drc AND --gc=orc, asserts exit 0 +
    ├── manifest.ms     #   peak-RSS bound. The ONLY tier that runs the C runtime
    └── programs/*.ms   #   (DRC/ORC/actor/spawn). Runner: run.ms + manifest.ms (msc run).
```

> **Why `native/` exists:** every other tier runs through the Bun transpiler
> (`test-ms`), which executes MetaScript-as-TypeScript on Bun and **never runs
> the emitted C runtime**. DRC over-free, ORC cycle-collector faults, actor
> scheduler and spawn-pool leaks are all invisible to `test-ms` — that blind
> spot shipped real regressions green. `native/` is the runtime guard: real
> binary, both GC modes, exit-code + peak-RSS assertions.

---

## 3. Patterns

### 3.1. Inline `test "name" { ... }` block

Use for **local, function-level invariants**. Most tests in `src/**/*.ms`
modules are this kind.

```ms
test "createResult — ok type accessible via getResultOkType" {
    const r = createResult(numberType(), stringType());
    assert isResult(r);
    const ok = getResultOkType(r);
    assert ok !== null && ok.kind === TypeKind.Number;
}
```

Rules:
- One assertion concept per test.
- Test name = the invariant in plain language.
- Place in the same file as the code under test (close to source).
- `assert` only — no `expect()`-style chaining.

### 3.2. Language tests (`lang/*.ms`)

End-to-end, user-visible language behavior. No compiler imports — the file
must compile cleanly to C. Used by both the bun-transpiler test runner AND
the C self-host pipeline.

```ms
test "Generic DU — multiple instantiations coexist" {
    const a = eitherDivStr(10, 2);
    const b = eitherDivInt(10, 0);
    if (a.ok) assert a.value === 5;
    if (!b.ok) assert b.error === -1;
}
```

Rules:
- One file per feature group.
- Every `lang/foo.ms` must be imported in `index.ms`.
- Use only the standard library and language features — never reach into
  `src/checker/`, `src/codegen/`, etc.
- If the bun transpiler can't handle a syntax (e.g. complex match-types),
  fix the transpiler in `bun/transform.ts` rather than skipping the test.

### 3.3. Regression tests (`fixedbugs/bugNNN_*.ms`)

One file per shipped bug. Append-only — old entries never get deleted or
refactored, even if the underlying API changes.

Required header block:
```ms
// bugNNN — <one-line summary>
//
// Symptom:    <what the user observed>
// Root cause: <where the actual fix lives, file path optional>
// Fix:        <what changed — one line>
//
// Body: minimal repro as a `test "bugNNN: <slug>" { ... }`.
```

Rules:
- File name: `bugNNN_short_slug.ms` where `NNN` is the next free 3-digit
  number. Look at the highest existing number in `fixedbugs/` and add 1.
- Test name: `"bugNNN: <slug>"` so failures point back to the file.
- Keep the repro minimal — the smallest program that triggers the bug.
- Add the import to `fixedbugs/index.ms`.

### 3.4. Pipeline tests (`c/*.ms`, `js/*.ms`)

Test the FULL pipeline (parse → check → transform → analyze → codegen)
using `compileToC` / `compileToJS` from `helpers.ms`. Inspect the emitted
C/JS source directly.

```ms
test "Result.ok lowers to tagged union literal" {
    const out = compileToC("function f(): Result<number, string> { return Result.ok(42); }");
    assert out.ok;
    if (out.ok) {
        assert out.value.contains("._tag = ");
        assert out.value.contains(".v0.value = 42");
    }
}
```

Rules:
- Useful for asserting **that codegen emits a specific C/JS pattern**.
- Avoid pinning every byte of output (brittle); pin the load-bearing tokens.
- These are NOT a substitute for runtime behavior tests — pair with a
  `lang/*.ms` test that runs the same code.

### 3.5. Phase-handoff tests (`handoff/*.ms`)

Pin contracts BETWEEN phases. E.g. "after transform, every `MatchExpr` is
gone" or "after analyze, every RC-typed local has a destroy call". Catches
silent contract drift between adjacent phases.

### 3.6. Differential corpus programs (`differential/programs/*.ms`)

Standalone programs (not `test {}` files) that print to stdout and exit.
The runner (`differential/run.sh`) compiles each program through every
lane and byte-compares outputs pairwise — no golden files, nothing to
bless, nothing to drift. Lanes today: C binary vs JS-on-node; planned
(§7 P1): C-drc vs C-orc, -O0 vs --danger, and a sanitizer lane.

Authoring contract — the runner stays a dumb byte-compare; ALL
determinism obligations live on the program:

- **Deterministic stdout only**: no timers, no randomness, no
  pointer/address or RSS/timing prints. Ordered output, fixed loop bounds.
- **Directive head** — the first two lines may carry directives, one per
  line:
  - `// @exit: <n>` — expected exit code for all lanes (default 0).
  - `// @skip-js: <reason>` — C-only program; the JS lane skips it and
    logs the reason. The skip list doubles as the JS backend's worklist.
- **Name files `NNN-topic.ms`**, clustered by hundreds (0xx basics,
  1xx strings, 2xx DU/match, 3xx closures, 4xx async/actor, 5xx std).
  Append-only, like `fixedbugs/`.
- **Write RC-stress shapes deliberately**: churn in loops, values relayed
  through calls then dropped unread, throw/catch unwinding mid-build,
  refcounted values held across await. The plain lane asserts behavior;
  the same program under the sanitizer lane becomes a leak/double-free
  probe for free.

Divergences between lanes are CONTRACTS, not normalizations: when lanes
legitimately differ (e.g. uncaught-error report format on stderr), the
runner documents it once (stderr is not compared for `@exit:` programs) —
it never fuzzy-matches. If float printing differs between the C and JS
lanes, fix number formatting in the runtime once; never paper over it in
the runner.

### 3.7. Lifecycle guards (`guard/*.ms`)

One invariant per file, built with the DRC ledger (`-DMS_DRC_LEDGER`):
aborts on the 2nd finalize of a live pointer, dumps per-type
alloc/destroy balances at exit. A guard is only trusted after it has been
PROVEN RED against the drift it targets. Methodology and ledger details:
`guard/README.md`; runner: `guard/run.sh`.

---

## 4. Anti-patterns (DO NOT DO THESE)

- ❌ **Tests in `/tmp/` or `examples/`** — they don't run on the next dev's
  machine. Always under `src/test/`.
- ❌ **One mega-test that asserts 20 things** — split into focused tests.
  When one assertion fails, you want to know which one.
- ❌ **Refactoring or deleting regression tests** — even if the API changed,
  the bug shape is permanent. Adapt the surface, keep the repro.
- ❌ **`console.log` in tests** — use `assert`. The test runner doesn't
  inspect stdout for correctness.
- ❌ **Skipping a flaky test** instead of root-causing — flakiness is a bug
  in the test or the system, not a thing to silence.
- ❌ **Coverage by self-host alone** — self-host green tells you "the
  compiler compiles itself", not "the feature works". Add an explicit
  language test.
- ❌ **Cross-cutting bugs without explicit tests** — when DU + generics +
  RC + closures interact in a fix, add a `lang/` or `fixedbugs/` test that
  exercises that exact combination.
- ❌ **Fuzzy comparison in a differential runner** — never "normalize until
  it passes". Nondeterminism is fixed by rewriting the PROGRAM (or
  classifying it out of a lane), not by weakening the comparison. Any
  normalization must be individually enumerated in the runner with its
  reason attached.
- ❌ **A non-obvious test file without a header stating its split** — when a
  test deliberately does NOT live in the most obvious tier (e.g. can't be
  differential because only one lane checks the behavior), open the file
  with a short comment saying why and where its siblings live.

---

## 5. Running Tests

```bash
# === PRIMARY: native msc (no Bun) — compiles a C test binary and runs it ===
# Full suite (lang + c + js + handoff + fixedbugs)
# ⚠ KNOWN RED (2026-07-27): 74 latent type errors — this entry historically
# ran only under Bun test-ms, which SKIPS the MS checker; it has never
# passed native type-check. Verified identical at clean HEAD c227ded, so
# not caused by any working-tree WIP. Migration campaign: §7 P1.
msc test src/test/index.ms

# Compiler internal tests (inline `test {}` blocks across src/)
msc test src/index.ms

# Under the ORC cycle collector (drc is the default)
msc test src/index.ms --gc=orc

# Run a single example for hand-debugging
msc run examples/foo.ms

# === Native leak/crash guard tier — a separate curated program set (manifest.ms)
# built as real binaries under BOTH --gc=drc and --gc=orc with peak-RSS bounds.
# A MetaScript dogfood runner (no Bun): it builds each program via msc, runs it
# under /usr/bin/time -l, asserts exit + RSS + stdout. Point MSC at a HEAD-matched
# binary so a stale installed msc can't cause false build-fails. `msc test` runs
# the inline `test {}` blocks; THIS runs the leak/crash probes. ===
MSC=./msc msc run src/test/native/run.ms

# === Differential corpus — every differential/programs/*.ms through both
# backends (C binary vs JS-on-node), stdout byte-compared. ===
MSC=./msc src/test/differential/run.sh

# === nim-guard lifecycle tier — DRC-ledger builds; see guard/README.md ===
src/test/guard/run.sh

# === Bun bootstrap fallback — transpiles the compiler to TS, NEVER runs the C
# runtime (blind to DRC/ORC/codegen). Only when msc can't self-run yet. Supports
# --filter / --jobs (msc test does NOT). ===
bun run test-ms src/test/index.ms
```

The native runner (`msc test <file>`) compiles the file + its transitive
dep tests to a C binary and runs it — the primary path. The Bun fallback
(`bun run test-ms`) spawns `bun test` with a `.ms` shim and transpiles
MetaScript to TypeScript via `bun/transform.ts`. **On the fallback path, if
a test fails to PARSE through the transpiler, fix the transpiler — do not
weaken the test.**

---

## 6. When You Fix a Bug — Mandatory Checklist

1. Reproduce the bug with a minimal program. Save it.
2. Apply the fix.
3. Convert your minimal repro into `fixedbugs/bugNNN_short_slug.ms` with
   the header block (Symptom / Root cause / Fix).
4. Add the import to `fixedbugs/index.ms`.
5. If the bug is observable from a program's stdout/exit (codegen, DRC,
   runtime behavior — not checker internals), ALSO drop the repro into
   `differential/programs/` as a corpus program (§3.6): one file then
   guards both backends and every future lane.
6. Run `msc test` on the files you touched (e.g. `msc test
   src/test/lang/match.ms` — the file plus its transitive dep tests) —
   must pass.
7. Run `msc test src/index.ms` — must stay at baseline (no regressions).
8. If the bug was found via self-host, ALSO add a focused test in the
   appropriate `lang/*.ms` so future devs hit it without needing self-host.

This is not optional. Without step 3, the bug WILL re-regress.

Same rule for features: a user-visible feature lands together with corpus
programs that pin its observable behavior through every lane (§3.6).

---

## 7. Progress Tracker

Status legend: ✅ done · 🚧 in progress · 🔲 todo

### P0 — Foundation (the "guard the bugs we just fixed" tier)

- [x] ✅ `src/test/lang/discrim.ms` — 4 DU shapes + generic mono + multi-instance coexistence + RC interaction (18 tests, 2026-05-03)
- [x] ✅ `src/test/lang/result.ms` — extended with edge cases: `Result<T,T>`, nested Result, ref/array/string payload, 3-deep `try` chain, Result+Either coexistence, `Result<void, E>` construction (17 new tests, 2026-05-03)
- [x] ✅ `src/test/fixedbugs/` — directory created, pattern documented, 2 entries:
  - `bug001_du_structural_key_collision.ms` (genUnionType named-named cache collision)
  - `bug002_ref_gi_mono_name.ms` (peelToStructOrUnion lost mono name through Ref<GI>)
- [x] ✅ `bun/transform.ts` — generic match-type DU now supported in transpiler (regex extended, boolean disc literals preserved instead of being numbered)
- [x] ✅ Wired into `lang.ms` + `index.ms`

Current baseline: full native suite green — `msc test src/index.ms` **3338/0** (2026-07-27).

### P0.5 — Native runtime guard (the "test-ms is blind to the C runtime" tier)

- [x] ✅ `src/test/native/` — builds real binaries via clang, runs under BOTH
  `--gc=drc` and `--gc=orc`, asserts exit 0 (no over-free/UAF/crash) + peak RSS
  under bound (no leak). Runner `run.ms` + `manifest.ms` via `msc run` (no Bun;
  replaces the old `bun/test-native.ts`).
  Seeded 5 cases; on first run it immediately caught **2 real leaks** invisible
  to `test-ms` (call-result-in-non-RC-context, array-literal-of-strings — both
  xfail anchors) and proved bug033 + PARALOCK spawn/actor/async hold natively.
  This is the tier that would have caught the over-free crash in 149eb30 and the
  "Bug D" leak-fix-gone-over-free that both passed `test-ms` green.

### P1 — Differential corpus + diagnostics (reprioritized 2026-07-27)

- [x] ✅ C↔JS differential runner — `differential/run.sh` + first programs
  (nullable, truthy), byte-exact stdout parity (2026-07-10).
- [ ] 🚧 Corpus growth 2 → ~60 programs per the §3.6 authoring contract
  (directive head, NNN-topic numbering, RC-stress shapes). First blocker
  to probe: float-formatting parity (C printf vs JS Number.toString) —
  if they differ, fix runtime number printing once; never normalize in
  the runner.
- [ ] 🔲 Matrix lanes in run.sh: + C-drc vs C-orc, + -O0 vs --danger;
  sanitizer lane (`MSDIFF_SAN=1`: ASan + `-DMS_DRC_LEDGER`, every ledger
  must balance) over the same corpus.
- [ ] 🔲 JS-lane tier auto-discovery — attempt EVERY corpus program through
  the JS backend instead of hand-picking; a refusal must be a loud
  diagnostic naming the first unsupported construct (never silently-wrong
  JS); the refusal histogram becomes the JS backend's roadmap queue.
  Prerequisite: the JS backend must refuse loudly — compiler change,
  needs separate approval.
- [ ] 🔲 Diagnostics snapshots — supersedes the old substring errorcheck
  idea: a diagnostics corpus where every program MUST fail to compile and
  the complete rendered diagnostic (code, span, message) is snapshotted.
  Changing one character of an error message becomes a deliberate,
  reviewed act.
- [ ] 🔲 Disc-read on narrowed DU variant — `if (n.kind === A) return; n.kind`
  (residual union) and disc reads after full narrow both fail: flow narrowing
  drops the union's discriminant metadata AND member-emit only routes
  disc→`_tag` for the full union. Needs a coordinated checker+codegen fix
  (checker stamps a disc-read marker; codegen stays dumb). Checker-only fix
  attempted and REVERTED 2026-07-27 — type-check went green but codegen
  emitted `n->v2.kind` (payload-relative, miscompile). Reference for the
  narrowing semantics: the TS checker (flow.ms already tracks its
  getTypeOfDottedName family); tsc types the residual disc as a union of
  literal types. lang/discrim.ms evalNode is split per-variant until this
  lands. SAME FAMILY, worse: match-type BOOL-disc DU `if (r.ok)` miscompiles
  too (emits payload-relative `.v0.ok` then stringTruthiness wraps it in
  `.byteLength` — SHAPE 4 never compiled natively either), and match-type
  string-field `===` on a narrowed variant emits raw C `==` (known bug,
  separate memory w/ 20-line repro). discrim.ms is the gate's stop point
  until this DU-codegen campaign lands — both errors reproduce at clean
  HEAD c227ded with the installed msc, so they are NOT caused by any
  2026-07-27 change.
- [ ] 🔲 Codegen baseline tests — for critical patterns (DU layout, Result lowering, closure lifting) commit expected `.c` snippets in `src/test/c/snapshots/` and diff on regen.
- [ ] 🔲 Native-checker migration of `src/test/index.ms` — 74 latent type
  errors from the Bun era (test-ms never type-checked). Three buckets:
  TS-isms the checker doesn't cover (block-local type aliases,
  intersection/branded types — parser skipIntersectionTail discards `&`
  tails), plain MS-invalid test code (`.includes` on string, stale field
  names, assert outside test blocks), and suspected real checker gaps
  (NodeData alias resolution shows type '' in fixedbugs/bug028;
  compileProjectToC Array-arg mismatches ×8 — root-cause before touching
  tests). Until green, the native full-suite gate does not exist.

### P2 — Coverage & infrastructure

- [ ] 🔲 Stage-3 self-host bootstrap check — stage 2 compiles itself, output compared with stage 3 (Rust-style `same-result` test).
- [ ] 🔲 Line/branch coverage measurement — instrument the C output to identify untested paths.
- [ ] 🔲 Property-based testing harness — small generator for AST shapes to fuzz transforms.
- [ ] 🔲 End-to-end realistic-program tests — compile + run a non-trivial real program (small webserver, JSON parser) as a smoke test.

### Backlog (nice-to-haves, no committed slot)

- [ ] 🔲 DU validation gaps in `resolvePass.ms:1197-1217` — duplicate variant keys, missing-variant exhaustiveness for boolean and enum discs (Task #78).
- [ ] 🔲 Cross-module DU usage stress test (one module defines, another consumes).
- [ ] 🔲 DRC + DU stress: nested generics with RC fields, multiple destruction orders.
- [ ] 🔲 Listening-process differential pattern — server fixture binds port 0
  and reports the real port on stderr (the never-compared channel); ONE
  shared driver script talks to whichever lane is up; server stdout + exit
  code + driver stdout all byte-compared. Deliberately deferred until
  Photon needs E2E server tests.
- [ ] 🔲 Corpus build caching + sharding — content-addressed keys over
  program bytes + toolchain fingerprint. Only when corpus wall-time hurts;
  premature below ~200 programs.
- [ ] 🔲 Absorb `js/` pipeline pins (2 files, 68 loc) into the differential
  JS lane once the matrix runner lands — behavior parity there supersedes
  brittle emitted-text pins.
- [ ] 🔲 Trim `examples/` after the differential corpus absorbs the
  valuable ones. NOTE: examples/ is almost entirely UNTRACKED in git —
  deleting is unrecoverable; 13 docs reference it. Never bulk-delete.
- [ ] 🔲 Array-destroy contract pin — ONE `c/` test pinning the final
  cleanup mechanism (generic `msArrayDestroy` + TypeInfo; primitives emit
  no per-array destroy), to be written AFTER array-migration Phase 3c
  lands and the mechanism stops moving. The old per-kind-name pins
  (ex-drcArray tier) went stale mid-migration and were removed 2026-07-27;
  runtime coverage lives in native/ refArray* + fixedbugs/bug033..035.

---

## 8. Update Protocol

Whenever you ship test changes that move the needle on coverage:

1. Update the relevant ✅/🚧/🔲 marker above.
2. If a new tier is started, add a new section.
3. If a P0/P1/P2 item is reclassified (e.g. promoted from backlog),
   record the date and reason in the bullet.

Treat this file as living documentation. It's the canonical answer to
"are we guarded enough?" — keep it honest.
