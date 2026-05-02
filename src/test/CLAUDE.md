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
- **Self-host bootstrap** as the integration test of last resort.

What "solid" means here:

| Property | Definition |
|---|---|
| **Discoverable** | A new dev can answer "where do I add a test for X" in <30s. |
| **Reproducible** | Tests live in version control and run identically on every machine. NEVER scratch files in `/tmp/`. |
| **Locked-in** | Every shipped bug fix has a regression test. Old tests are append-only — never delete or refactor regression repros. |
| **Cross-cutting** | The hard interactions (DU + generics + RC + closures + async) have explicit tests, not implicit coverage via self-host. |
| **Fast feedback** | Inline tests run on every `bun run test-ms`. Bootstrap runs in CI. |

---

## 2. Directory Layout

```
src/test/
├── CLAUDE.md           # this file
├── helpers.ms          # compileToC / compileToJS / compileProjectToC|JS
├── index.ms            # full test suite (lang + c + js + handoff + fixedbugs)
├── lang.ms             # language-only subset (no compiler imports — C-backend safe)
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
└── handoff/            # phase-handoff contracts
    └── index.ms
```

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
- Every `lang/foo.ms` must be imported in BOTH `lang.ms` and `index.ms`.
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

---

## 5. Running Tests

```bash
# Full suite (lang + c + js + handoff + fixedbugs)
bun run test-ms src/test/index.ms

# Language-only subset (fast, runs through bun transpiler)
bun run test-ms src/test/lang.ms

# Compiler internal tests (inline `test {}` blocks across src/)
bun run test-ms src/index.ms

# Run a single example for hand-debugging
bun run run-ms run examples/foo.ms
```

The test runner spawns `bun test` with a `.ms` shim that imports the
target file. The bun transpiler (`bun/transform.ts`) converts MetaScript
syntax to TypeScript so Bun can execute it. **If a test fails to PARSE
through the transpiler, fix the transpiler — do not weaken the test.**

---

## 6. When You Fix a Bug — Mandatory Checklist

1. Reproduce the bug with a minimal program. Save it.
2. Apply the fix.
3. Convert your minimal repro into `fixedbugs/bugNNN_short_slug.ms` with
   the header block (Symptom / Root cause / Fix).
4. Add the import to `fixedbugs/index.ms`.
5. Run `bun run test-ms src/test/lang.ms` — must pass.
6. Run `bun run test-ms src/index.ms` — must stay at baseline (no
   regressions).
7. If the bug was found via self-host, ALSO add a focused test in the
   appropriate `lang/*.ms` so future devs hit it without needing self-host.

This is not optional. Without step 3, the bug WILL re-regress.

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

Result: `bun run test-ms src/test/lang.ms` → **159 pass / 0 fail** (was 138 before this push). Self-host stable at **2749/9** baseline.

### P1 — Codegen drift detection

- [ ] 🔲 Codegen baseline tests — for critical patterns (DU layout, Result lowering, closure lifting) commit expected `.c` snippets in `src/test/c/snapshots/` and diff on regen.
- [ ] 🔲 C↔JS differential testing — pick 5-10 `lang/*.ms` tests that don't use C-only features, compile via both backends, run, compare runtime output.
- [ ] 🔲 Errorcheck-style tests — annotate `.ms` files with `// expect-error: <substring>` markers and assert the checker emits matching errors at the expected lines.

### P2 — Coverage & infrastructure

- [ ] 🔲 Stage-3 self-host bootstrap check — stage 2 compiles itself, output compared with stage 3 (Rust-style `same-result` test).
- [ ] 🔲 Line/branch coverage measurement — instrument the C output to identify untested paths.
- [ ] 🔲 Property-based testing harness — small generator for AST shapes to fuzz transforms.
- [ ] 🔲 End-to-end realistic-program tests — compile + run a non-trivial real program (small webserver, JSON parser) as a smoke test.

### Backlog (nice-to-haves, no committed slot)

- [ ] 🔲 DU validation gaps in `resolvePass.ms:1197-1217` — duplicate variant keys, missing-variant exhaustiveness for boolean and enum discs (Task #78).
- [ ] 🔲 Cross-module DU usage stress test (one module defines, another consumes).
- [ ] 🔲 DRC + DU stress: nested generics with RC fields, multiple destruction orders.

---

## 8. Update Protocol

Whenever you ship test changes that move the needle on coverage:

1. Update the relevant ✅/🚧/🔲 marker above.
2. If a new tier is started, add a new section.
3. If a P0/P1/P2 item is reclassified (e.g. promoted from backlog),
   record the date and reason in the bullet.

Treat this file as living documentation. It's the canonical answer to
"are we guarded enough?" — keep it honest.
