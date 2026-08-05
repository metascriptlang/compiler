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
- **Program corpus** — the same program through independent executions
  (C-drc vs C-orc vs `--danger` vs JS-on-node), outputs byte-compared, plus
  `@maxrss` RSS cells and an `MSCORPUS_SAN=1` sanitizer lane
  (`corpus/`, §3.6). No golden files: the other execution IS the expected
  output, so tests can't drift.
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
  - `// @maxrss: <MB>` — RSS program: built + run under `--gc=drc`,
    `--gc=orc` and `--danger` (`-O3 -flto`, `--cc=clang`) via
    `/usr/bin/time -l`, asserting exit + signal + stdout + peak RSS (the
    former native/ tier semantics).
  - `// @stdout: <substr>` — merged output must CONTAIN the substring.
    Enforced on every lane (RSS, SAN **and** parity — parity cells checked
    exit code only until 2026-08-04). Byte-compare across lanes stays the
    primary assertion, so most programs still want no `@stdout`; reach for
    it when the lanes cannot judge correctness on their own, i.e. when
    every lane could be wrong in the same way (see `013-int64Fidelity`,
    which additionally grades itself into the exit code).
  - `// @xfail(<lane>): <reason>` — known-fail for one lane; XPASS is
    reported loud so a stale marker cannot lie silently.
  - `// @serial` — contention-sensitive (actor/spawn stress): its run
    cells execute one at a time after the parallel drain.
  - `// @ledger-slack(<MangledType>): <N>` — san lane only: exactly N
    objects of that type legitimately survive exit (module-level RC
    values are NOT destroyed at exit — probe-verified 2026-07-29; the
    compiler-side question is open). EXACT-match: a diff other than N
    fails, and diff 0 with slack declared fails as "slack unused" so the
    marker self-cleans if global-destroy ever lands. Never use @xfail for
    a survivor — it would mask every future real leak in that program.
- **Programs WITHOUT `@maxrss` are parity programs**: run through C-drc,
  C-orc, C-danger and (unless `@skip-js`) JS-on-node.
- **EVERY program is byte-compared across all of its lanes** — no golden
  files, nothing to bless, nothing to drift. The axes are independent and
  each catches its own class: C↔JS (backend), drc↔orc (GC mode changing
  observable behaviour), O0↔danger (UB the optimizer is free to exploit,
  and DCE masking leaks). A program whose output legitimately differs on
  one axis is classified out with `@xfail(<lane>)` and a reason — never
  by weakening the comparison.
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

**25 test files are not imported by any entry** (22 below + 3 found by the
2026-07-29 corpus migration; excluding `guard/`, which has its own `run.sh`). None carry an `xfail`/parked marker, so this is
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
cd src/test && for f in $(find . -name '*.ms' -not -path './corpus/programs/*' \
  -not -path './native/programs/*' -not -path './guard/*' -not -name 'run.ms' \
  | sed 's|^\./||'); do base=$(basename $f .ms)
  n=$(rg -l "/${base}\"|\./${base}\"" --glob '*.ms' . | grep -v "^\./$f$" | wc -l | tr -d ' ')
  [ "$n" = "0" ] && [ "$base" != "index" ] && echo "$f"
done
```

---

## 5. Running Tests

### 5.0 Which command, when — read this first

| Situation | Command | Cost |
|---|---|---|
| **Inner loop** — any compiler edit | `msc test src/index.ms` | ~40s |
| Same, under the cycle collector | `msc test src/index.ms --gc=orc` | ~40s |
| Touched **codegen / DRC / runtime / transform** | + `msc run src/test/corpus/run.ms` | ~19 min |
| Touched **DRC hooks, lifetimes, ownership** | + `MSCORPUS_SAN=1 msc run src/test/corpus/run.ms` | ~10 min |
| Same, targeted lifecycle invariants | + `src/test/guard/run.sh` | ~2 min |
| Touched **std/** or anything users compile against | rebuild + `tools/sync-local-binary.sh` first, then re-run the above | — |
| Before shipping / after a risky refactor | the full ladder below | ~35 min |

**Pre-ship ladder** — run in this order, stop at the first red:

```bash
msc build src/index.ms --gc=drc --danger --cc=clang --output=msc  # 0. build the candidate → ./msc
msc test src/index.ms                                             # 1. inline suite (baseline 3404/0)
msc test src/index.ms --gc=orc                                    # 2. same under ORC
msc run src/test/corpus/run.ms                                    # 3. corpus: parity + RSS lanes
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms                     # 4. corpus: SAN lane
src/test/guard/run.sh                                             # 5. lifecycle guards
./tools/sync-local-binary.sh                                      # 6. only once green: publish
```

The two corpus lanes are **deliberately two separate runs**, not one merged
invocation (same split as the reference frame's plain/sanitized lanes):
they assert different things, and they run on different cadences — the SAN
lane is a ship gate, while the RSS cells are the slow backstop that may run
in the background (§T1.1 in `docs/TESTGAP.md`). Both must be green to ship.

### Which compiler is under test — the two-tree convention

A compiler resolves `std/` and `runtime/` **relative to its own location**
(verified, not assumed), so the binary you run decides which support trees
come with it:

| binary | is | reads std/ + runtime/ from |
|---|---|---|
| `./msc` (repo root) | the candidate you just built | **this repo** — your edits |
| `msc` (PATH → `~/.metascript/bin/msc`) | the last PUBLISHED build | `~/.metascript/` — the last sync |

So the loop is: edit the repo → `msc build … --output=msc` (the published
compiler builds the candidate) → **test the candidate** → `./tools/sync-local-binary.sh`
only once green (publish: candidate + repo std/runtime become the installed
ones). Between build and sync the two trees legitimately differ — that gap is
the whole reason the runners must be told which compiler to exercise.

Convention, applied by `corpus/run.ms` and `guard/run.sh` alike:

- **Default = `./msc` when it exists**, else the installed `msc`. Plain
  `msc run src/test/corpus/run.ms` therefore tests what you just built, with
  no ceremony.
- **`MSC=<path>` overrides** (e.g. `MSC=msc` to check the published build,
  or a release binary for a bisect).
- The chosen binary is **printed in the runner header** — never silent.
- Two roles, two binaries, on purpose: `msc run <runner>` compiles/executes
  the *harness* (use the stable published one — a broken candidate must not
  stop the harness from starting), while `MSC` names the *subject under test*.
  Running `./msc run <runner>` alone inverts this: the harness gets the new
  compiler while every corpus program is still built by the old one.

Other rules that make these numbers real:

- **Never `rm -rf out` first.** It throws away the object cache AND triggers
  the cold-build link race (§5.2).
- **Never run two `msc` builds concurrently** — including from another
  terminal or another agent session. Concurrent builds race the shared
  `out/` object cache; that is the single biggest source of "red that names
  a different file every run". Check `uptime` before trusting any timing.

### 5.1 Commands in detail

```bash
# === PRIMARY: msc test — compiles a C test binary and runs it ===
# Full suite (lang + c + js + handoff + fixedbugs)
# ⚠ PARTIALLY RED (2026-07-30): the 74 latent type errors are GONE — this entry
# now passes the checker clean. It fails later, in C codegen, on 2 files (was 14):
# bug006 + lang/syntax, one array/pointer-repr cluster entangled with the
# in-flight array migration.
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
# progress streams to stderr. Tests ./msc by default (see the two-tree
# convention above); MSC=<path> overrides. ~19 min full (was >40).
msc run src/test/corpus/run.ms
MSCORPUS_FILTER=leak msc run src/test/corpus/run.ms  # substring subset
MSCORPUS_JOBS=4                                      # run slots
MSC=msc msc run src/test/corpus/run.ms               # test the PUBLISHED build instead

# === SAN lane — same corpus, every program built once (drc) with ASan +
# slab-off + the DRC ledger; asserts exit + @stdout + no ASan report + no
# DOUBLE-DESTROY + per-type ledger balance (@ledger-slack for exit
# survivors). ~10 min full. The ledger IS the leak signal here (no LSan on
# this platform); RSS cells backstop the destroy==0 blind spot. ===
MSCORPUS_SAN=1 msc run src/test/corpus/run.ms

# === nim-guard lifecycle tier — DRC-ledger builds; see guard/README.md ===
src/test/guard/run.sh
```

The runner (`msc test <file>`) compiles the file + its transitive dep tests
to a C binary and runs it.

---

### 5.2. Cost model — the build dominates, so just run the whole battery

**Re-measured 2026-07-28, and it INVERTS the previous advice.** Sharing prelude
contexts (commits `2c0c677`, `76a7222`) cut test EXECUTION by ~14×, which left
compiling the test binary as almost the entire cost of any `msc test`. Picking a
smaller entry no longer buys much, because you still pay a build.

| command | build | run | wall |
|---|---|---|---|
| `msc test src/test/fixedbugs/bug048.ms` (14 files) | ~18s | 2.7s | **20s** |
| `msc test src/compiler/meta/expand.ms` (69 files) | ~45s | 4.8s | **49s** |
| `msc test src/index.ms` — 167 files / 3404 tests | ~21s | 17-19s | **40s** |
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
- **Aggregator status**: `src/test/index.ms` now type-checks clean but 2 files
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

Current baseline: full native suite green — `msc test src/index.ms` **3411/0**, 168 files (2026-08-05), drc AND orc.
Corpus **382 pass / 0 fail / 3 xfail** (509/510 json-strict added 2026-08-05, parity all 4 lanes);
SAN **92 / 0 / 1 xfail**; nim-guard ALL GREEN (2026-08-04).
Self-host fixpoint the same day: **emitted-C 0/292 differ** between gen-2 and gen-3,
and the two binaries differ only inside `LC_CODE_SIGNATURE` (the ad-hoc signature
embeds the `--output` name; `LC_UUID` matches). Recipe, since nothing scripts it:
build gen-N+1 with gen-N, `rm -rf out/release/.cache` before each generation so the
emission is actually regenerated, snapshot the cache, then compare the two `.c` sets.
Give every generation a distinct `--output` or msc self-skips with "Up to date" and
you compare a stale cache against itself.

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
- [ ] 🚧 Corpus growth 86 → ~120 programs per the §3.6 authoring contract
  (directive head, NNN-topic numbering, RC-stress shapes). New programs
  should prefer parity (no @stdout) over @stdout-contains; strip @stdout
  from migrated deterministic programs over time to upgrade them to
  byte-compare.   Cluster census (2026-08-04, 85 programs): 0xx=5, 1xx=5,
  2xx=13, 3xx=5, 4xx=13, **5xx=5**, 6xx=31, 7xx=8 — next: 505/506 json,
  507/508 fs.
  - 5xx std grew 2026-08-01 post string-contract P1/P2 (js = native
    strings + native Map/Set): `501` dropped its @xfail(js) (all-lane
    green), `502-mapChurn` (pins the re-insert-to-end ordering rule),
    `503-arrayOps`, `504-hashContainers` (sorted canonical prints — hash
    containers promise no iteration order). 503 immediately caught TWO
    latent bugs: `concat()` was 100% broken on C (runtime kept a stale
    by-value param from before the array migration; zero callers hid it)
    and the js `sort<T>` bind was bare `#.sort()` = lexicographic on
    numbers. Both fixed same-day.
  - 21x conditional-evaluation trio landed 2026-08-05 (97 programs total):
    `215-shortCircuitNrvo` (statement-emitting `&&`/`||` RHS ran
    unconditionally on C — parity, JS is the spec lane),
    `216-matchShortCircuit` (match-expr in `&&`/`||` RHS or ternary arm
    hoisted out of its guard by the SHARED lowerMatch pass — BOTH backends
    over-executed identically, so this one pins effect counts via `@stdout`;
    byte-parity alone is blind to it), `217-assignEvalOrder`
    (`arr[idx()] = c ? a : b` evaluated RHS before the LHS index on C; TS
    order is LHS-first). All three proven red pre-fix; fixes live in
    conditionalExprLower (universal `&&`/`||` guarded rewrite + do-while
    per-iteration condition + assignment target-effects pre-hoist) and
    matchLower (position-aware hoist).
  - `250-brandDistinct` landed 2026-08-01 with TSGAP item 5 S1 (branded
    primitives: nominal in the checker, erased at runtime) — parity all
    lanes incl. js; guard bug074.
  - 24x match-lowering landed 2026-07-31 (`240-matchShadowUninit`,
    `241-matchShadowBothRun`, `242-matchShadowOrderSwap`) — proven red
    pre-fix (241 exit=133 on all three native lanes): lowered
    `const x = match(...)` lost its checker symbol and collided with a
    same-named sibling `let` in the hoisted C slot.
  - 3xx closures landed 2026-07-31 (`300-closureBasics`,
    `301-closureMutation`, `302-closureEscape`, `303-closureShared`,
    `304-closureChurn`) — all parity incl. js (loop-capture is
    per-iteration on BOTH backends; env ledger types `dollarEnv_*`
    balance exactly). Found two compiler bugs on the way: a local named
    `log` CAPTURED by a closure marks the prelude `console.log` extern
    alive and its TU emits `static void log(...)` colliding with math.h
    (capture-free `log` locals are fine — probe /tmp/log-collide); and
    `new Error(...)` is `Undefined variable 'Error'` under `--target=js`
    while every C lane accepts it (corpus convention throws strings, so
    only the JS worklist is affected).
  - Float-formatting blocker CLEARED 2026-07-30: all 20 probed cases
    already agree (the C runtime implements ECMAScript
    `Number::toString`, not printf `%g`), pinned by `012-floatFormat`.
  - 1xx strings landed 2026-07-30 (`100-stringBasics`,
    `101-stringIndexSpace`, `102-stringSearch`, `103-stringBytes`,
    `104-stringChurn`) — the cluster paid for itself immediately by
    finding two JS-backend bugs the unit tiers could not see:
    self-append was not alias-safe in `index.jms` (C had the fix,
    guarded only by `627`, which carries `@maxrss` and therefore never
    gets a js cell at all), and the bundler emitted module-private decls
    unqualified so two modules sharing a helper name either silently
    resolved to the wrong one (`function`) or failed to parse
    (`const`/`let`). Both fixed (`d8fedf5`, `9c2fec0`).
- [x] ✅ SAN lane — SHIPPED 2026-07-29 (`MSCORPUS_SAN=1`): whole corpus
  under ASan + slab-off + DRC ledger, 61 pass · 3 fail (the 3 = the same
  externally-reproduced reds: 010 G1 carrier, 701/702 macro-WIP). Proven
  RED end-to-end via a fake-imbalance probe before being trusted. Ledger
  balance is slack-aware (`@ledger-slack`, §3.6) because module-level RC
  values are NOT destroyed at exit (probe-verified; compiler-side question
  OPEN — when resolved, every slack marker goes red as "slack unused" and
  gets removed). Ledger set size is overridable (`-DMS_LEDGER_SET_SIZE`,
  runtime/drc.c #ifndef) since ASan's freed-address quarantine makes the
  finalized-pointer set append-only — the 1M default overflows on
  3M-churn programs. Build flake-retry ported from guard/run.sh.
- [x] ✅ Remaining matrix lanes in corpus/run.ms — LANDED 2026-07-30.
  Every program is now byte-compared across all its lanes, not just C↔JS:
  RSS programs gained the drc↔orc compare for free (both cells already
  ran; only the comparison was missing) plus a new `danger` cell
  (`-O3 -flto`, `--cc=clang` — zig cannot LTO on Mach-O); parity programs
  gained `orc` + `danger`. 127 → **241 pass** with ZERO new programs, no
  lane divergence found. `--cc=clang` is not a workaround: `--danger`
  defaults to `--lto=thin` (options.ms), and native-macOS zig + any LTO is
  rejected outright (toolchain.ms) — the compiler's own advice is
  "`--cc=clang`, or drop `--lto`". Keep the LTO: whole-program DCE is
  exactly the class this lane exists to catch. Warm per-program build on
  601-closureArray: 0.31s clang+thin vs 0.41s zig+`--lto=off`, identical
  runtime, 262 KB vs 294 KB. Cold-cache build timings on this tree swing
  by ~10x — never quote one.
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
  **2 files, down from 14** (2026-07-30): 6 fell to `assertMessageExpr`
  missing from the AST child-walkers, `bug008` to a module-blind
  generic-instance dedup, `bug010`+`bug047` to bare value-type `T | null`
  carriers in call and equality position, `fmt/roundtrip` to enum
  reverse-index + request-driven `Enum_toString` injection, and
  `stress/deepNesting`+`handoff/classMemberElseIf` to banning `any` (they
  were the tree's only two users of it). The last 2 are `bug006` +
  `lang/syntax` — one array/pointer-repr cluster, entangled with the
  in-flight array migration. They are pre-existing latents the
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
