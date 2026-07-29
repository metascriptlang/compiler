# Test Suite — Standards & Progress Tracker

This is the source of truth for **how testing works in this project**. It
defines what "solid" looks like, where each kind of test lives, and tracks
which guardrails are already in place vs still missing.

When you add or modify tests, **update the progress section at the bottom**.

Companion file: **`docs/TESTGAP.md`** tracks defects in the test HARNESS
itself — where running the tests is slow, misleading, or where a tier exists
but nothing invokes it. This file answers "what do we test and where does a
test go"; that one answers "why does testing cost what it costs".

The program-corpus layer follows ONE proven frame (scriptc): a single
numbered corpus + directive heads + a dumb parallel runner, extended one
piece at a time (san lane → diagnostics snapshots → CAS cache + lock).
Tiers that are not program-corpus shaped (inline tests, guard/, bootstrap
fixpoint) deliberately stay outside that frame.

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
└── corpus/             # THE program corpus (scriptc frame) — one program set,
    ├── run.ms          #   many lanes. Flat NNN-topic.ms or NNN-topic/main.ms;
    └── programs/       #   contract in each program's directive head (§3.6).
                        #   Absorbed the former native/ (RSS cells) and
                        #   differential/ (parity cells) tiers, 2026-07-29.
```

> **Why `corpus/` exists:** the other tiers assert test-level outcomes inside
> one large test binary. DRC over-free, ORC cycle-collector faults, actor
> scheduler and spawn-pool leaks often fail no assertion — they surface as
> crashes or RSS growth in a standalone binary. Corpus programs are real
> binaries, one process per cell: RSS programs run under BOTH GC modes with
> exit-code + peak-RSS assertions; parity programs run through independent
> executions (C vs JS today) and their outputs are byte-compared — no golden
> files, the other lane IS the expected output.

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
must compile cleanly to C via the self-host pipeline.

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

### 3.6. Corpus programs (`corpus/programs/`)

Standalone programs (not `test {}` files) that print to stdout and exit —
flat `NNN-topic.ms`, or `NNN-topic/main.ms` with sibling modules for
multi-module cases. ONE runner (`corpus/run.ms`, MetaScript dogfood)
executes every program through its lanes; planned lanes (§7 P1): C-drc vs
C-orc parity, -O0 vs --danger, and a sanitizer lane over the same corpus.

Authoring contract — the runner stays a dumb executor; the program's
contract lives entirely in its directive head (leading `// @...` comment
lines), and ALL determinism obligations live on the program:

- **Directive head** — one directive per line:
  - `// @exit: <n>` — expected exit code, all lanes (default 0).
  - `// @skip-js: <reason>` — C-only program; the JS lane skips it and
    logs the reason. The skip list doubles as the JS backend's worklist.
  - `// @maxrss: <MB>` — RSS program: built + run under BOTH `--gc=drc`
    and `--gc=orc` via `/usr/bin/time -l`, asserting exit + signal +
    stdout + peak RSS (the former native/ tier semantics).
  - `// @stdout: <substr>` — merged output must CONTAIN the substring
    (legacy native assertion; new parity programs should omit it and rely
    on byte-compare instead).
  - `// @xfail(<lane>): <reason>` — known-fail for one lane; XPASS is
    reported loud so a stale marker cannot lie silently.
  - `// @serial` — contention-sensitive (actor/spawn stress): its run
    cells execute one at a time after the parallel drain.
- **Programs WITHOUT `@maxrss` are parity programs**: run through C and
  (unless `@skip-js`) JS-on-node, outputs byte-compared pairwise — no
  golden files, nothing to bless, nothing to drift.
- **Deterministic stdout only**: no timers, no randomness, no
  pointer/address or RSS/timing prints. Ordered output, fixed loop bounds.
- **Name files `NNN-topic`**, clustered by hundreds (0xx basics,
  1xx strings, 2xx DU/match/types, 3xx closures, 4xx async/actor,
  5xx std, 6xx RC/DRC stress, 7xx meta/macro/jsx).
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
- ❌ **Writing a test file without wiring it into an index** — the entries
  import an explicit list; a file nobody imports is silently never run and
  looks like coverage that does not exist. See §4.1.

### 4.1 Orphan test files — audited 2026-07-28

**22 test files are not imported by any entry** (excluding `guard/`, which
has its own `run.sh`). None carry an `xfail`/parked marker, so this is
neglect, not policy. The worst case is `fixedbugs/bug048.ms` — it guards a
real self-host regression (collectPass hoisting test-block-local `const`
to module scope) and it **passes today**, so the guard exists but has
never protected anything.

```
handoff/   toStringType matchIfChain resultTypeAlias classNew
           nilableUnknownCastError ccgPtrClosure selfRefField diag
           classNewDebug staticExtern unionParam drcHookParams   (12)
lang/      nullable nullableFunction inheritance                  (3)
paralock/  spawnOnly actorOnly asyncOnly                          (3)
std/http/  websocket websocketServer                              (2)
fixedbugs/ bug048                                                 (1)
c/         asCoercionNullable                                     (1)
```

The 2026-07-29 corpus migration surfaced 3 MORE: `native/programs/`
`actorCycleStress.ms`, `ctorExtProtocol.ms`, `ctorExtProtocolLib.ms` were
never referenced by `manifest.ms` — programs that existed but no runner
ever executed. They were deliberately NOT migrated (no contract to carry
over); triage them with the rest of this list.

Triage so far (partial — the machine was loaded, see the flakiness note
in §5): `lang/nullable` passes (296), `fixedbugs/bug048` passes (278),
`lang/inheritance` fails for real (`Unresolved type 'Admin'`). The rest
were inconclusive: repeated runs flipped between pass and `link failed`,
which is the known cold-build link race, not a verdict.

Wire the passing ones; give each failing one a header saying what it
proves and why it is parked, or delete it. Re-run the audit with:

```bash
cd src/test && for f in $(find . -name '*.ms' -not -path './native/programs/*' \
  -not -path './differential/programs/*' -not -path './guard/*' -not -name 'run.ms' \
  | sed 's|^\./||'); do base=$(basename $f .ms)
  n=$(rg -l "/${base}\"|\./${base}\"" --glob '*.ms' . | grep -v "^\./$f$" | wc -l)
  [ "$n" = "0" ] && [ "$base" != "index" ] && echo "$f"
done
```

---

## 5. Running Tests

```bash
# === PRIMARY: msc test — compiles a C test binary and runs it ===
# Full suite (lang + c + js + handoff + fixedbugs)
# ⚠ PARTIALLY RED (2026-07-28): the 74 latent type errors are GONE — this entry
# now passes the checker clean. It fails later, in C codegen, on 5 files (was 14;
# 6 fell to the assertMessageExpr child-walker gap, bug008 to a module-blind
# generic-instance dedup, bug010+bug047 to the bare Maybe-carrier positions).
# Pre-existing latents that the old checker abort was hiding, not regressions.
# Inventory: docs/TSGAP.md "G1-gate".
msc test src/test/index.ms

# Compiler internal tests (inline `test {}` blocks across src/)
msc test src/index.ms

# Under the ORC cycle collector (drc is the default)
msc test src/index.ms --gc=orc

# Run a single example for hand-debugging
msc run examples/foo.ms

# === Corpus tier — every corpus/programs/ entry through its lanes: RSS
# programs (@maxrss) as real binaries under BOTH --gc=drc and --gc=orc with
# peak-RSS bounds; parity programs through C + JS-on-node, byte-compared.
# msc builds are serial (out/ cache race), runs are parallel (except @serial),
# progress streams to stderr. Point MSC at a HEAD-matched binary so a stale
# installed msc can't cause false build-fails. ~19 min full (was >40).
MSC=./msc msc run src/test/corpus/run.ms
MSCORPUS_FILTER=leak MSC=./msc msc run src/test/corpus/run.ms  # substring subset
MSCORPUS_JOBS=4                                                # run slots

# === nim-guard lifecycle tier — DRC-ledger builds; see guard/README.md ===
src/test/guard/run.sh
```

The runner (`msc test <file>`) compiles the file + its transitive dep tests
to a C binary and runs it.

---

### 5.1. Cost model — the build dominates, so just run the whole battery

**Re-measured 2026-07-28, and it INVERTS the previous advice.** Sharing prelude
contexts (commits `2c0c677`, `76a7222`) cut test EXECUTION by ~14×, which left
compiling the test binary as almost the entire cost of any `msc test`. Picking a
smaller entry no longer buys much, because you still pay a build.

| command | build | run | wall |
|---|---|---|---|
| `msc test src/test/fixedbugs/bug048.ms` (14 files) | ~18s | 2.7s | **20s** |
| `msc test src/compiler/meta/expand.ms` (69 files) | ~45s | 4.8s | **49s** |
| `msc test src/index.ms` — 164 files / 3346 tests | ~21s | 17-19s | **40s** |
| ↑ same, first run after a large tree change | ~51s | 17s | **69s** |

Yes, that table is right: the **full battery (40s) beats a single-module test
(49s)**. A narrower entry links a different binary whose cache entries are colder,
and the tests it skips were cheap anyway. So:

**Default to `msc test src/index.ms`.** Reach for a single entry only when you
want a focused failure list, not to save time.

`msc test <file>` still runs EVERY inline test in that file's transitive
dependency closure — that part of the old model holds. What changed is that the
closure's tests are no longer the expensive part.

| you changed | run | why |
|---|---|---|
| any compiler module | `msc test src/index.ms` | 40s, covers everything, usually the cheapest option anyway |
| a checker / codegen RULE | `msc test src/test/fixedbugs/bugNNN.ms` | runs the SOURCE checker, so it proves RED/GREEN *before* any rebuild (dodges the bootstrap trap) |
| `std/`, or anything users compile against | rebuild + `tools/sync-local-binary.sh`, then re-run downstream suites | the installed `msc` resolves `std/` from `~/.metascript`, NOT from this repo — a repo-only edit measures nothing |

Traps, all measured rather than assumed:

- **`out/` DOES cache `msc test`** — this reverses the previous note. A no-change
  re-run rebuilds in 21s versus 51s after a large tree change (2.5×). The old
  "cold 240s vs warm 237s" reading was taken when per-test prelude rebuilding
  swamped everything; with that gone, the object cache is clearly visible. **Do
  not `rm -rf out` before a suite** — besides losing the cache it triggers the
  cold-build link race below.
- **Cold-build link race.** `rm -rf out` followed by a suite fails with
  `undefined symbol: __ms_tests_…` or `failed to deduplicate literals`. Re-running
  warm is clean. Any red that names a DIFFERENT file each run is this, not your
  change.
- **Timings swing 6-8× with machine load.** Another session's `zig` build put the
  8-core machine at load 28 and turned a 29s suite into 251s, and flipped
  individual files between pass and `link failed`. Check `uptime` before trusting
  any number, and never conclude from single runs — one such pair suggested a
  fresh binary was 2.3× slower than the installed one; a controlled A/B (`rm -rf
  out` on both sides, same minute) showed 32.47s vs 32.25s, i.e. identical.
- **`msc check` is not a fast gate.** It exits quietly on this repo's relative
  imports and has missed a deliberately planted type error. Never use it to
  decide whether you are green.
- **`msc test` accepts exactly one file** — no directories, no globs, no
  `--filter`. Grouping is only possible through an aggregator module.
- **Aggregator status**: `src/test/index.ms` now type-checks clean but 5 files
  fail C codegen (see the banner in §5 and docs/TSGAP.md "G1-gate");
  `src/test/fixedbugs/index.ms` is red for one of them, `bug006`. Do NOT
  repeat the claim that these "pass standalone" — that was true only of
  bug008 (its generic instance collided by name with bug007's, so it needed
  an aggregate to fail); bug006/bug010/bug047 all failed standalone too, and
  the belief they did not delayed root-causing them.

Where the remaining time actually goes, if you want to attack it:

1. **`orchestrator.ms` is ~16s of the ~20s run time** — its 19 tests each call
   `checkModuleGraph`, which builds a fresh prelude BY DESIGN (it stamps
   `targetOs` on that context). Fixable by adding `targetOs` to the prelude cache
   key, which would let the production build path share too — deliberately NOT
   done: it is the build path, and ~16s of test time is a poor trade for a
   cross-compilation state-leak risk.
2. **~21s of build floor on a no-change re-run** — the object cache skips
   codegen/clang, but the front end still re-loads and re-checks all 283 modules
   every run. Removing it means caching checked ASTs across processes (what
   `TransAmDb` does for the LSP). Real project, not a tweak.
3. **`msc test <file> --filter=<pattern>`** — still worth having for focused
   failure lists, but no longer a performance lever.

---

## 6. When You Fix a Bug — Mandatory Checklist

1. Reproduce the bug with a minimal program. Save it.
2. Apply the fix.
3. Convert your minimal repro into `fixedbugs/bugNNN_short_slug.ms` with
   the header block (Symptom / Root cause / Fix).
4. Add the import to `fixedbugs/index.ms`.
5. If the bug is observable from a program's stdout/exit (codegen, DRC,
   runtime behavior — not checker internals), ALSO drop the repro into
   `corpus/programs/` as a corpus program (§3.6): one file then
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
- [x] ✅ `src/test/fixedbugs/` — directory created, pattern documented; seeded with
  - `bug001_du_structural_key_collision.ms` (genUnionType named-named cache collision)
  - `bug002_ref_gi_mono_name.ms` (peelToStructOrUnion lost mono name through Ref<GI>)

  and grown to **bug001–bug059** (2026-07-28; 59 imports in `index.ms`, plus the
  `bug005helper` / `bug059helper` sibling modules that their owners import, and
  `bug048` which is still an orphan — see §4.1).
- [x] ✅ Wired into `lang.ms` + `index.ms`

Current baseline: full native suite green — `msc test src/index.ms` **3346/0**, 164 files (2026-07-28).

### P0.5 — Native runtime guard

- [x] ✅ `src/test/native/` — grown to 61 manifest cases; on first run it caught
  **2 real leaks** no other tier saw and proved bug033 + PARALOCK
  spawn/actor/async hold natively. This is the tier that would have caught the
  over-free crash in 149eb30 and the "Bug D" leak-fix-gone-over-free that both
  shipped green. **MIGRATED into `corpus/` 2026-07-29**: all 61 cases became
  corpus programs (`@maxrss` + `@stdout` directive heads, manifest notes
  preserved as `// note:` headers); verdict semantics unchanged (exit + signal
  + stdout-contains + per-process peak RSS, drc AND orc, per-lane xfail with
  loud XPASS). 3 orphan programs surfaced by the migration (see §4.1).

### P1 — Differential corpus + diagnostics (reprioritized 2026-07-27)

- [x] ✅ C↔JS differential runner — `differential/run.sh` + first programs
  (nullable, truthy), byte-exact stdout parity (2026-07-10). **SUPERSEDED
  2026-07-29 by `corpus/run.ms`**: one MetaScript-dogfood runner over the
  unified corpus (63 entries = 61 ex-native + 2 ex-differential), serial
  msc builds pipelined with parallel background runs (@serial cells drain
  alone at the end), stderr streaming, per-lane xfail, build-fail logs.
  First full run: 122 pass · 5 fail in ~19 min under load 6-21 (old
  native runner: >40 min serial) — the 5 fails all reproduce outside the
  runner (010-nullable = the known G1 nullable-carrier gap; 701/702 = the
  in-tree macro-evaluator WIP regression). The old differential runner
  swallowed build failures (`>/dev/null` + no "Built" check) and could
  run a STALE binary from a previous round as a false pass — the corpus
  runner closes both holes.
- [ ] 🚧 Corpus growth 63 → ~120 programs per the §3.6 authoring contract
  (directive head, NNN-topic numbering, RC-stress shapes). First blocker
  to probe: float-formatting parity (C printf vs JS Number.toString) —
  if they differ, fix runtime number printing once; never normalize in
  the runner. New programs should prefer parity (no @stdout) over
  @stdout-contains; strip @stdout from migrated deterministic programs
  over time to upgrade them to byte-compare.
- [ ] 🔲 Matrix lanes in corpus/run.ms: + C-drc vs C-orc parity, + -O0 vs
  --danger; sanitizer lane (`MSDIFF_SAN=1`: ASan + `-DMS_DRC_LEDGER`,
  every ledger must balance) over the same corpus.
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
- [x] ✅ Disc-read on narrowed DU variant — LANDED 2026-07-27 (`eedc6d2`
  checker, `4499aef` codegen disc contract, `f7cefed` BooleanLiteral
  truthiness, `99b2892` nested-GI alias bodies). `lang/discrim.ms` is the
  regression guard: `evalNode` is back to a sequential `if` chain
  (`bea5869`) and the file is green 294/294 under drc AND orc.
- [ ] 🔲 Codegen baseline tests — for critical patterns (DU layout, Result lowering, closure lifting) commit expected `.c` snippets in `src/test/c/snapshots/` and diff on regen.
- [ ] 🚧 Native full-suite gate `src/test/index.ms` — **the type errors are
  gone** (74 → 0; the last two, `jsonValueOf`'s `got Node, expected Node`,
  fell to the structural `typeRelation` work). It now fails in C codegen on
  **5 files, down from 14** (2026-07-28): 6 fell to `assertMessageExpr`
  missing from the AST child-walkers, `bug008` to a module-blind
  generic-instance dedup, `bug010`+`bug047` to bare value-type `T | null`
  carriers in call and equality position. They are pre-existing latents the
  old checker abort was hiding — identical errors before and after.
  Inventory + error-class census + the remaining clusters: docs/TSGAP.md
  "G1-gate". Fix those and this gate joins the standing ladder.

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
