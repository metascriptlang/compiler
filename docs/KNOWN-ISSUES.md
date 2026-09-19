# Known Issues

Bugs and gaps you can hit writing MetaScript with the self-hosted `msc`.

**Every claim in this file was measured on 2026-09-02** against `./msc` @ main `81090cc`
(cross-checked at `8c61416`). Memory-lifetime probes were re-run under ASan with
`-DMS_DRC_LEDGER` and the alloc/destroy counts are quoted. There are no unverified entries left:
if something is not listed below, it is not a known issue — go measure before believing otherwise.

**Re-audited 2026-09-04** (every Live entry re-probed on one binary: snapshot `8506c8ff` + the
L1/L4 fixes built in a private worktree — no binary on the box builds current HEAD, see the
self-host section): L1 ✓ resolved, L2 **narrowed** (original repro now errors; one shape still
silent), L3 ✓ still live (`noproc`), L4 ✓ resolved (this binary), L6 ✓ resolved,
L7 still broken with a **moved first error**, L5 ✓ resolved (this pass — see the L5
section, incl. the cross-module C fix and the pre-existing JS cross-module residual),
L8 ✓ resolved (this pass — see the L8 section). Not re-measured this pass: the two
runtime sections below (self-host RED, 405 SAN wedge) — they belong to the in-flight
float-narrowing / bootstrap arc.

The 22 numbered entries this file used to carry were written against the pre-self-host bootstrap
compiler. Seventeen of them no longer reproduce; they are kept as a one-line ledger at the bottom
rather than as instructions, because their "Fix:" advice now teaches workarounds for bugs that
are gone.

---

# Live issues

## ~~L1. `break` in a match arm — silent no-op~~

**Status: RESOLVED — fixed 2026-09-03** with a labeled-break model end-to-end (`jumpRetarget` transform + label-aware CFG + labeled break/continue in both backends; switchLower deletes terminal case-breaks and wraps non-terminal ones in a labeled `do{}while(false)`). Measured on both backends, snapshot `8506c8ff` + the fix: match-arm `break` now exits the loop (`b1=3`, nested `b5=3,20`), `continue` still skips (`12`), and — the two sibling bugs found while tracing it — a `break` inside a user `switch` case now exits the **switch** (`s2=15,ggSgg`, was exiting the loop) and a `break` in a switch outside any loop now compiles (`s4`, was a checker error). Guard: `src/test/guard/breakJumpTargets.ms` (proven red on the pre-fix binary). Zero cost measured: for programs without break-in-dispatch the emitted C is byte-identical to the pristine-snapshot control build. Gates: suite 174/3528 green, guards ALL GREEN, corpus parity 813/814 + SAN 166/167 (the 1 = a pre-existing `306-closureIife` runner timeout, standalone-green and emit-identical), GEN2/GEN3 fixpoint identical after path normalization.

**Problem (historical):** `break` inside a match arm leaves the generated switch, not the enclosing loop. The loop keeps running and nothing is reported.
**Repro (historical):** `for (const x of [1,2,3,4]) { match (x) { 3 => { break; }, _ => {} }; sum += x; }` → `sum` was `10`; the correct answer is `3`.
**Severity:** was **silent** — wrong results, no diagnostic.

---

## L2. Discriminated-union read through the wrong variant — silent wrong value (RESOLVED 2026-09-04)

**Status: RESOLVED** by a checker rule + four narrowing-model completions, all following the existing flow-graph design (no new mechanisms):

1. **New rule** (`duFieldRequiresNarrowing`, `src/checker/types.ms`): an un-narrowed field read off a union is legal only when EVERY variant declares the field with an identical layout signature. This generalizes the old offset-divergence guard to the subset case (`s.circ` when `circ` exists on one variant only) — the silent class measured this morning (`s.circ.rad` printing `3`, the rect payload's bits, with codegen emitting `(*s).v1.circ` against an inactive slot). Maybe unions (`T | null`) are exempt: the null side carries no fields and payload reads are governed by the null-check paths.
2. **Pinned-variant reads** (`src/checker/callResolve.ms`): a reference the flow graph pinned to variant V can no longer read another variant's payload field — previously "let through" whenever the field existed union-wide. The discriminant itself stays readable (variant structs do not re-declare it; disc re-reads inside narrowed blocks were always legal).
3. **`assert e;` narrows the rest of the block** (`src/binder/binder.ms`): assert aborts on the false side, so flow continues through the TrueCondition edge exactly like an `if (e)` body. This is what std/json tests (`assert r.ok; r.value...`) had been silently relying on.
4. **`exit(...)` is noreturn** (`src/binder/binder.ms`, bare `exit` and `process.exit` only): `if (!r.ok) { exit(1); } r.value` now narrows on the fall-through path.

Semantic note: narrowing requires a REAL DU — literal/enum/boolean discriminant. A union of `{ kind: string, ... }` variants (declared `string`, not `"circ"`) has no discriminant, cannot be narrowed, and now REJECTS subset reads that it previously accepted by reading same-offset bytes luckily. That acceptance was the bug. In-suite pin: `checkPass` "string DU subset field outside if is rejected" (flipped from pinning the old lenient behavior — that test was literally asserting the hole).

Std/compiler source fixes the rule exposed (all in-tree, mechanically): `std/serialize/json/parser.ms` (runtime un-narrowed `keyResult.node.strVal` now disc-checked; tests gained kind-asserts), `orchestrator.ms` (unguarded `pr.value` after recovery parse — guard + continue now), `lockfile.ms`/`registry.ms` (element reads `depsObj.values[i].strVal` hoisted to a local — ArrayAccess refs are unnarrowable by design), `destructorLifting.ms` (2 test helpers did `if (!pr.ok) return pr.value;` — a latent wrong-variant read, now `null as unknown as Node`).

**Known edges kept open (measured, loud or documented):**
- **Wildcard match arms don't complement-narrow**: `match (s.kind) { "circ" => m.circ.rad, _ => m.rect.w }` rejects the `_` arm's `m.rect` (no complement flow synthesized). Explicit arms (`"rect" =>` ...) narrow fine. Workaround: write explicit arms.
- **ArrayAccess refs (`arr[i]`) are unnarrowable by design** (`@nondotted` in the flow model — Phase 6 territory per flow.ms comments). `a[i].kind === K && a[i].f` doesn't narrow; hoist to a local first.
- `Result.ok<Vec<int32>,string>(new Array<int32>(2))` (L4 edge, unchanged).

Gates (snapshot `8506c8ff` + L1/L4/L2): probes 15/15 expected outcomes (subset/offset/pinned/match/chained/maybe); suite **174 files / 3528 green** after the in-suite flip; guard `src/test/guard/duVariantNarrowedReads.ms` (GUARD-JS) green on C + JS — its red side is the compile-rejection pinned in checkPass (the runtime values were already correct via same-offset luck, so the guard pins narrowing routing, not the hole); corpus + SAN lanes run post-commit.

**Workaround (pre-fix code):** narrow on the discriminant (`if`/`match` with explicit arms, `assert` of the discriminant) before touching a variant-specific field.

---

## L3. Actor CALL awaited inside an `async function` — `noproc`

**Problem:** Awaiting an actor's returning method from inside an `async function` aborts the program with `Error: unhandled exception: noproc`.
**Repro:** `async function work(): Promise<number> { const c = new Counter(); c.bump(5); return await c.get(); }` then `await work()` → `noproc`. The same actor is fine when driven from synchronous code.
**Related:** from a synchronous caller, `c.get()` yields `<Promise>` — the CALL result is a future, so sync code cannot observe the value either.
**Severity:** loud, but it makes actor CALLs unusable from the async half of a program.
**Workaround:** none known. Drive CALLs from sync code, or have the actor push results out via SEND.

---

## ~~L4. Generic instantiation rejects explicit type arguments~~

**Status: RESOLVED — fixed 2026-09-04** (checker `callResolve.ms` `inferGenericReturnWithExplicit`: multi-arg explicit type args now bind generic params positionally — parity with the reference's `explicitGenericInstantiation` → `setGenericParams` + `matchGenericParams`; for `Class.static<...>` calls the param names come from the class's generic decl when the method itself carries none). Measured: `Result.ok<int32, string>(5)` → `5`, `Result.err<int32, string>("boom")` → `boom`, positional order honored (`Result.ok<string, int32>("x").value + "!"`), free fn needing both args (`tagged<T,E>`) green — C and JS lanes. Partial explicit (`Result.ok<int32>(5)` with 2 params) still errors, matching the reference (partial explicit instantiation is a type mismatch there). Annotated-destination and single-arg forms unchanged. Guard: `src/test/guard/explicitGenericArgs.ms` (proven red on the pre-fix binary — the two original errors reproduce — green after).
**Known edges (verified, left open):** (a) an explicit-arg call whose payload arg is a `new` expression boxed into a value struct (`Result.ok<Vec<int32>, string>(new Array<int32>(2))`) passes the checker but fails at C emit — the arg is not contextually typed on this path; the annotated-destination spelling compiles and runs. Loud, alternative spelling exists. (b) `Box.make(5)` / `Box.make<int32>(5)` — static methods on a generic CLASS — was a separate, pre-existing emission gap (checker bound the return but the static's body was never emitted, `call to undeclared function 'Box_make__…_u0'`, with or without explicit args); **fixed by L8 later the same day** (see the L8 section).

**Problem (historical):** `Result.ok<int32, string>(5)` failed with `cannot instantiate: 'E' — annotate the destination type or pass an explicit type argument` — while passing an explicit type argument is exactly what the call does. Root cause: the parser captured the full comma-joined arg list (`"int32,string"`) but the checker's explicit-arg consumer was single-arg-only — it looked the whole string up as one symbol name, failed, and fell back to pure inference, which cannot solve `E` for `Result.ok`. Only the annotate-the-destination half of the advice worked.

---

## ~~L5. Method overload inside a `class` — C compile error~~

**Status: RESOLVED — fixed 2026-09-04.** A class method now gets its emitted-name disambiguator from the same mechanism a free function gets it from: `collectClassMethod` chains a same-named sibling onto the first one's `overloadSet` and takes the next slot (exactly `defineSymbol`'s rule), so each method mangles to its own `…_u<N>`. Numbering is per (class, method-name) and spans static and instance methods together — the C name places both in one namespace, so a counter split by static-ness puts a static and an instance method of one name back on the same emitted name. JS statics lift through `jsSymbolName` and pick the index up for free, JS instance members get a `_u<N>` member suffix (decl + call site read the same `resolvedSym.overloadIdx`). The import side already numbered exported overload sets positionally, so cross-module C calls line up once one dead guard is removed: `autoPropagateModuleExtensions`' overload loop required `findExtension(recv, name) === null`, which is always false right after the primary registers — that guard silently dropped EVERY cross-module extension overload (standalone-ext overloads included), not just method ones. **Measured on the gated snapshot binary (302 modules built clean):** same-module overload by param type `int:5 str:x` on C **and** JS (was: clang `conflicting types … _u0` on C, silently last-body-wins on JS); by arity `2 5` both targets; static overload `static-int:5 static-str:x` both targets (was: JS `Identifier … already been declared` SyntaxError); differing return types `s:x` both targets; checker already picked the right symbol pre-fix (no-match still errors with the full candidate list). **Cross-module C fixed by the same change**: class in one module, calls in another → `int:5 str:x static-int:7 static-str:y` (was: every call bound the primary `_u0`). Free-fn overload, standalone-ext overload and single-method controls re-measured green throughout. **Gates:** probe matrix p1–p10 × {C, JS} = 17 green / 3 red-by-design (the no-match diagnostic on both targets, and residual (a) below); suite 174 files / 3528 tests RC=0; self-host fixpoint emitted-C **302/302 byte-identical** (v13→v14→v15); corpus `258-classMethodOverload` byte-identical across C and JS including the shared-name case; regression `fixedbugs/bug129_classMethodOverload.ms` (5 tests; its own lane is 15 files / 297 — `src/index.ms` does NOT pull the test tree, so the 3528 figure never covered it). Corpus full-lane runner not re-run for this fix (descoped, same as L2/L8). **Known residuals, deliberately out of scope:** (b) A `;`-terminated body-less method in the same class as a same-named body-bearing one keeps today's behaviour (loud clang collision on C, last-wins on JS) — root cause is the parser conflating TS-style sigs with abstract/extern methods (`declaration.ms` gives them an empty BlockStmt and NO sig marker, unlike functions which get the `overload` flag); the numbering deliberately skips them, so nothing gets silently-worse. (c) **Cross-module instance-method calls on JS are broken pre-existing and stay broken**: the call is lowered to free-call `Box_describe(b, 5)` (referencing a binding the defining module never emits — it emits a class member), so the bundle dies at `export { Box_describe … }` — measured identical on the pre-fix binary with a single method, i.e. NOT caused by this fix; root is `extensionMethodLower`'s keep-as-member guard keying on `sym.declNode.kind === MethodDecl`, which imported syms (declNode not carried for non-generic methods) never match. Separate defect, separate arc.

**Addendum 2026-09-05 (measured):** the fix above is NOT at origin/main HEAD yet — it lives in the author's uncommitted tree. At clean HEAD `c39d6968`, `msc test src/test/fixedbugs/index.ms` is RED on `bug129_classMethodOverload` with every clean-built compiler (HEAD-built: 3 type errors at `new Box()`; installed bootstrap: 10 C errors `conflicting types … _u0`), while a binary built from the author's working tree passes 297/297. Until that WIP lands, a red fixedbugs lane at clean HEAD is THIS, not your change.

**Problem (historical):** Two same-named methods with different parameter types on a `class` emit two C functions with the same mangled name.
**Repro (historical):** `class Box { describe(n: int32): string; describe(s: string): string; }` → `error: conflicting types for 'Box_describe__…_u0'`.
**Severity (historical):** loud, at C compile time.
**Workaround (historical, now unnecessary):** free-function overloads resolve correctly on both targets; otherwise give the methods distinct names or dispatch inside one method.

---

## L6. JS target — a named function assigned to a closure-typed slot is not callable

**Status: FIXED 2026-09-02** (`85249fe3` checker: give an inferred function binding the closure convention; `69f74867` js codegen: emit a closure-wrapped function as the bare function on js; merged via `2b75a240`).
**Re-verified 2026-09-03** on installed msc v0.2.53 AND a HEAD-built binary, 7-shape matrix: init (`const f: IntFn = seed; f(7)` → 14), assignment (`let f …; f = seed` → 14), call-arg (`use(seed)` → 14), field (`{ cb: seed }` → 14), `typeof f === "function"`; direct call and arrow-slot neighbours green throughout.
**Pinned by:** `src/test/corpus/programs/750-fnValueClosureRepr.ms` (init/field/return forms, both lanes) and the `fromNamed` case in `742-closureReassignSink.ms` (assignment form; 9/9 values identical on drc/orc/js). Not re-run: the original `r4.ms` file itself — its two shapes (declaration + assignment) are covered by the matrix above.

---

## L7. `std/compress` does not build — `cparse` gaps on the vendored miniz header

**Problem:** Importing `std/compress` fails while parsing the vendored C header.
**Repro (re-measured 2026-09-04):** `import { deflate } from "std/compress";` → first error is now `C header vendor/miniz/miniz.h:117:1: 'miniz_export.h' file not found`, followed by the original `miniz.h:179:1: 'time.h' file not found` (the `miniz_export.h` miss is new since the 2026-09-02 audit — the vendored tree was modified in-place).
**Severity:** loud — the module has never been buildable.
**Workaround:** none. `cparse` needs the missing includes resolved and, past that point, `__inline__` support.

---

## ~~L8. Static method on a generic `class` — body never emitted, undeclared symbol at C compile~~

**Status: RESOLVED — fixed 2026-09-04.** A static of a generic class now owns the class's type params the way a generic free function owns its own: `collectClassMethod` stamps `gen:<classGenerics>` into the static's `methodFlags`, so every mono gate that keys on the method's own flags (call-site instantiation, template skip, codegen skip) fires exactly as for `makeBox<T>`. This is the same defect class the cross-module export gate already fixed 2026-07-21 (`methodCarriesMonoBody` = signature still mentions a generic param, not own-flags) — that fix renamed the criterion at one gate while three sibling gates kept the old own-flags test; L8 was the surviving instance. **Measured on the gated snapshot binary (8506c8ff + L1 + L4 + L2 + this fix, 302 modules built clean):** `Box.make<int32>(5)` → `g8=5`, annotated-destination `Box.make(7)` → `g8b=5`/corpus `annotated=7`, ctor-flow variant `g8c=7`; emitted C now carries `Box_make__int32__…_u0` and `Box_make__string__…_u0` as separate instances; JS lane byte-identical output (`g8js=5`, corpus 257 all lanes exit 0). Non-touched paths re-measured green: instance method on generic class (`g8d=9`), static on non-generic class (`g8e=4`). Gates: suite 174/3528 green, guards battery green at time of writing (running to completion), corpus lane not re-run for this fix (user descoped). Regression: `fixedbugs/bug128_staticGenericClassMake.ms` (3 tests) + corpus `257-staticGenericClass` (C-drc ↔ JS parity). Known residual, unverified: a static that declares its OWN `<U>` on a generic class merges no class params (only one `gen:` segment is honored — the method's own); no known code shape hits it.

**Problem (historical):** Calling a `static` method on a generic class passes the checker (return type binds) but the call site emits a reference to a static that is never instantiated or emitted — `error: call to undeclared function 'Box_make__…_u0'` (plus an int-to-pointer assignment error as fallout).
**Repro (historical, measured 2026-09-04, both forms identical):** `class Box<T> { v: T; static make(x: T): Box<T> { … } }; const b: Box<int32> = Box.make(5);` → C compile error. Same with `Box.make<int32>(5)` and with the instance body calling `new Box<T>(x)`.
**Boundary (historical):** independent of explicit type args — the no-explicit form fails identically. Non-static methods and constructors on generic classes instantiate fine (`new Box<int32>(7)` green). Free generic functions instantiate fine. **Severity:** loud, at C compile time.
**Workaround (historical, now unnecessary):** move the factory to a free generic function (`function makeBox<T>(x: T): Box<T>`), which instantiates and emits correctly.


---

# Open lead

## ~~L9. `spawn(namedFn)` — the compiler segfaults~~ (RESOLVED 2026-09-08)

**Fix:** `src/transform/lowering/spawnLower.ms` — the adapter arrow it synthesizes for a bare function reference carried no `arrowDefaults` (the lambda-lifting rename walk dereferenced it), and it rewrote the shared function TYPE of the named function to return `void*` instead of giving the wrapper its own. Guard: `src/test/guard/spawnNamedFunction.ms` (proven red: SIGSEGV pre-fix). Measured post-fix: fused and deferred `await spawn(fn)` both return the value.

**Problem:** Passing a named function (not an inline closure) to `spawn` crashes `msc` on `--target=c`; nothing is reported.
**Repro (measured 2026-09-08):** `function w(): int32 { return 1; } const f = spawn(w); await f;` → `msc build x.ms --target=c` exits 139 (SIGSEGV) on the installed binary, HEAD `3adfe8a1` and a clean-worktree build alike. `--target=raiser` is loud instead: `raiser runtime error: spawn expects a closure`.
**Severity:** loud in the worst way — a compiler crash with no diagnostic. The `spawn(() => w())` spelling is unaffected.
**Workaround:** wrap the call: `spawn(() => w())`. Note the checker's spawn-capture walk (`checkSpawnCaptures`) only runs for an inline closure, so a named function writing a module-level ref is also invisible to E24.

---

## ~~L10. Raiser — `++` / `--` on a member or index target does not compile~~ (RESOLVED 2026-09-08)

**Fix:** `src/codegen/raiser/expressions.ms` `compileUpdateExpr` — LoadField/StoreField and LoadIndex/StoreIndex branches, prefix returns the stored value, postfix the old one. Tests in `src/codegen/raiser/rgen.ms` (1472/1472).

**Problem:** The Raiser bytecode compiler handles `i++` on a plain local only; `o.n++` and `arr[i]++` fall through to `cannot compile update target: unsupported by the Raiser bytecode compiler`.
**Repro (measured 2026-09-08):** `const o: Counter = { n: 0 }; o.n++;` under `msc run x.ms --target=raiser` → the error above, HEAD `3adfe8a1`. `--target=c` is fine.
**Severity:** loud. Tier-1 gap in `src/codegen/raiser/expressions.ms` (`compileUpdateExpr` fallback).
**Workaround:** spell it `o.n = o.n + 1`.

---

## ~~L11. Prefix `++` / `--` bound tighter than `.` and `[]`~~ (RESOLVED 2026-09-08)

**Problem:** `++a[1]` parsed as `(++a)[1]` and `++o.n` as `(++o).n` on every target. Measured: C ran `++a[1]` and threw `index 1 out of bounds (length 0)`; Raiser trapped `array handle out of bounds: 1`; `++o.n` failed type-check with `Property 'n' does not exist on type 'int32'`. Postfix forms were fine.
**Fix:** `src/parser/expressions/core.ms` — the prefix update parses its operand as a postfix chain with no binary op (the `typeof` shape), `as` rebound outside. `src/checker/checkExprPass.ms` now rejects increment/decrement on a non-numeric operand (`++a` on an array used to silently type as `int32`). Regression: `src/test/fixedbugs/bug136PrefixUpdateOperand.ms`.

---

## L12. `msc test src/parser/expressions/core.ms` is red at HEAD `3adfe8a1` — quote test panics

**Problem:** The parser's scoped test lane aborts: `test "quote body is block"` panics with `member access within misaligned address 0x1 for type 'Node'` at `assert d.quoteBody.kind == NodeKind.BlockStmt`, taking the whole test binary down (`msc test` exits 255, no tally).
**Repro (measured 2026-09-08):** clean worktree at `3adfe8a1`, `./msc test src/parser/expressions/core.ms` with the HEAD `core.ms` — same panic (`__ms_test_26`), so it is not caused by any uncommitted edit. `msc test src/codegen/raiser/rgen.ms` and the fixedbugs lane, which import the parser, are green — only the direct `exprNode("quote { ... }")` unit path is affected.
**Also measured:** with the two `quoteBody` tests removed (worktree copy only) the lane reports `635 passed | 11 failed` at HEAD — the 11 are all in the func-expr / default-param / quote families (`func expr kind`, `generator func expr`, `async func expr`, `default param typed/expr body/block body`, `bare ident block body`, `capture number default via getLastParsedDefaults`, `multiple defaults via getLastParsedDefaults`, `quote kind`, `quote multi ok`), identical with or without the bug136 parser change.
**Severity:** loud; the parser unit lane cannot report anything until this is fixed.
**Workaround:** none for the lane; parser regressions are still caught by fixedbugs/corpus.

---

## L13. `std/http` does not type-check at HEAD `0f007c5a` — namespace-qualified extension calls

**Problem:** any program importing `std/http` fails with 18 errors, all of one shape: `Too many arguments to 'hasHeader': expected at most 1, got 2` at `std/http/server.cms:140` (and `getHeader`/`removeHeader`/`setHeader` at 141, 230–237, 373…). The call is `hdrs.hasHeader(res.headers, "content-type")` where `hdrs` is `import * as hdrs from "./headers"`; the resolver binds `server.cms`'s own extension `hasHeader(this res: ServerResponse, name)` instead of the namespace member and then rejects the arity.
**Repro (measured 2026-09-10):** HEAD-clean worktree at `0f007c5a`, `msc build` of a two-line program `import { createServer } from "std/http";` → rc=1, 18 errors. Identical set on the peer-built `./msc`.
**Severity:** loud; `std/http` is unusable until fixed. Not in any green gate today (the compiler does not import it).
**Workaround:** none.

---

## L14. Guard `duVariantNarrowedReads` is red at HEAD `0f007c5a` on all three lanes

**Problem:** `src/test/guard/duVariantNarrowedReads.ms` fails to build: `Argument type mismatch in '!=' arg 1: got string, expected "rect" — 'T' was bound by argument 0`. The binary-operand gate binds `T` from a string-literal discriminant and then refuses the comparison against a plain `string`.
**Repro (measured 2026-09-10):** HEAD-clean `msc_head build src/test/guard/duVariantNarrowedReads.ms` → same error; `src/test/guard/run.sh` reports `FAIL duVariantNarrowedReads [drc|orc|js]: build error`.
**Severity:** the guard suite cannot go all-green until the gate or the guard is corrected.
**Workaround:** none.

---

## L15. `src/test/c/actor.ms` has two red E2E tests at HEAD `0f007c5a`

**Problem:** `E2E C: 100 actors fan-out compiles` and `E2E C: S1/S3 — read-only field borrow in spawn thunk compiles` fail with `implicit number → int32 narrowing drops the fractional part — write an explicit 'as int32'` — the test sources mix `let i = 0` (int32) with `number` fields, and the narrowing rule now rejects that.
**Repro (measured 2026-09-10):** the two embedded sources extracted to files, `msc_head check` → same error on the HEAD-clean control. `msc test src/test/c/actor.ms` → `3023 passed | 2 failed`.
**Severity:** quiet; the rest of the actor lane is green.
**Workaround:** none (the test sources need `int32` fields or explicit casts).

---

## L16. Two spellings of one compiler root made builds link a runtime TU twice — `duplicate symbol definition: _mbedtls_ms_time` / two-hash instantiations — FIXED 2026-09-10 (uncommitted)

**Problem (was):** programs failed at link with `duplicate symbol definition` for runtime and vendor symbols, or at C compile with two instantiations of one generic under two names (`HashMapEntry__ref_Symbol_1k1en11_…` vs `…_s22s0i_…`, "incompatible type"), with no source change to blame. Seen 2026-09-10 in corpus cell `721-orphanRejectionExit`, ~190 guards in one lane, and the suite run right after a guard lane; it read like a code regression or a bloated `out/<mode>/.cache`, and clearing `out/` sometimes "cured" it.
**Root cause (pinned 2026-09-10, six-cell matrix under a private `HOME`, every prediction stated first):** the prelude pack `~/.metascript/cache/prelude/<key>.deps` stores the std module paths of the build that wrote it, keyed by tool stamp + std CONTENT (`preludePackKey`), and `seedPreludeModules` (`src/compiler/compile.ms`) rebuilds the std graph from those strings. Module identity was the normalized path STRING (`canonicalModulePath`, `src/module/loader.ms`) and the root came from `argv[0]` as spelled (`resolveRuntimeDir`, `src/utils/path.ms`), so a build invoked as `/private/tmp/<wt>/msc` after one invoked as `/tmp/<wt>/msc` (macOS `/tmp` is a symlink) seeded std under the pack's spelling and resolved `stdPath`, `-I` and `@compile` under its own: one build, two spellings of one root. Vendor sources reached from both sides compiled twice (36 `@compile` lines instead of 32) and both objects reached the link line; C type names embed `mangleModuleName(sym.modulePath)`, so generics instantiated under both spellings. The trigger in one sentence: **a build was red iff its root spelling differed from the spelling in the prelude pack it hit**; cwd, a warm `out/` and the global object cache were not part of it (`rm -rf out` only ever helped because the previous lane had rewritten the pack). Two binaries with different tool stamps sharing one `HOME` wipe each other's pack (`ensurePackMarker`), which is why a concurrent build changed the live spelling underneath a lane.
**Fix:** module identity is the physical path. New primitive `msFsRealPath` (`runtime/fs/header.h`, `posix.c` = `realpath(3)`, `windows.c` = `_fullpath` + existence check, no link resolution), exposed as `realpath(path): string` in `std/fs` on C, Raiser (`hostTable.ms` bridge) and JS (`realpathSync`), empty string when the path does not exist. `canonicalRootDir` and `canonicalModulePath` resolve through it and fall back to the spelled path when it is empty (map-provider test paths such as `/src/a.ms` stay as written). Pinned by unit tests in `src/utils/path.ms`, `src/module/loader.ms` (`/tmp` and `/private/tmp` share one identity on darwin) and `src/compiler/meta/hostTable.ms`.
**Measured on the rebuilt binary (same six-cell matrix, `A=/tmp/<rig>/msc`, `B=/private/tmp/<rig>/msc`, fresh `HOME` per pair):** every cell green, every build spells the root `/private/tmp/…` whatever `argv[0]` said, 32 `@compile` lines per build, one `Node__ZprivateZtmp…` identity, pack rows all `/private/tmp`. Before the fix the same matrix was red in the two cross-spelling cells (`_mbedtls_ms_time`), green with `MSC_NO_PRELUDE_PACK=1`.
**Second half (2026-09-11, found by a symlink-on-specifier probe):** the graph key was canonical but `ImportEntry.sourcePath` kept the resolved spelling, so `import … from "../link/dep"` (a symlink inside the tree) loaded one module and looked its exports up under another name → `Module '../link/dep' has no export`; before the fix the same shape silently built TWO modules (`depValue__…ZlibZdepOms` and `…ZlinkZdepOms`). `processImportDecl` now records the entry under `moduleIdentity()` (the same function `loadModule` keys on). Guard `src/test/guard/moduleIdentityPhysicalPath.ms` (fixture symlink `fixtures/moduleIdentity/link -> lib`, module-level counter): old binary `throughSymlink=1` GUARD-FAIL, fixed binary `=2` GUARD-OK on drc and orc.
**Gate (2026-09-11, worktree at `7b84deb6` + this fix + L17):** suite 180 files / 3679 tests green; guard 251 ok / 3 FAIL (`duVariantNarrowedReads` = L14, red on HEAD without this change); six-cell matrix green. Trap while gating: a HEAD-clean worktree built with the shared tree's `./msc` fails `Undefined variable 'msFsRealPath'` until it carries the runtime half too — std comes from the bootstrap binary's root, the C header from the worktree.
**Not covered:** a std tree reached through a symlink that is NOT the root's own (`canonicalizeStdModule` still rebases such modules onto `stdPath`, which is now the physical root, so the identity stays single but is the root's spelling, not the target's); C names still embed the module path rather than a name + signature hash (separate divergence, left while type identity is being reworked).

## L17. `msc fmt` hoisted a file's leading comment block into the first function body — FIXED 2026-09-10 (uncommitted)

**Problem (was):** a file that opens with `//` comment lines followed by a declaration came back from `msc fmt` with those comments moved INSIDE the first function or method body, ahead of its first statement; a comment written above a method landed inside it the same way. `msc fmt` rewrites the file in place, so a guard header comment silently landed inside the first method.
**Repro (measured 2026-09-10 on the shared `./msc` before the fix):** `printf '// header one\n// header two\n\nclass A {\n\tf(): int32 { return 1; }\n}\n' > min.ms; msc fmt min.ms` → `class A { f(): int32 { // header one  // header two  return 1; } }`.
**Mechanism:** `advance()` pushed comment tokens to `state.pendingComments` and `attachComments` harvested them only when a statement FINISHED parsing; recursive descent finishes the innermost statement first, so `return 1;` took the file header. The reference attaches a comment the moment it is met, to the construct under parse at that nesting level (`rawSkipComment`/`skipComment(p, node)`), and its renderer prints it there.
**Fix (same model):** `parseStatement` (`src/parser/statements/core.ms`) harvests the pending comments when a statement STARTS and prepends them to that statement's own list; the class and actor member loops (`src/parser/statements/declaration.ms`) harvest body comments at each member boundary onto the container node, which the printer already pairs to members by line. Measured on the rebuilt binary: `msc fmt` of `// header one / // header two / class A { // about f / f(): int32 { return 1; } }` keeps both blocks where they were written. Pinned by `src/test/fmt/cases/headerComment.ms` (header before class, header before function, body comment stays inside, comment before a method, comment between two statements); fmt tier 77 files / 1012 tests green; full suite 180 / 3679 and guard 247 ok on the `149eed3e` worktree (the 7 guard reds are HEAD's, see L16). Not covered: a comment block directly ahead of a top-level or block-level `when` still goes to the first statement inside it (`parseWhenChain` bypasses `parseStatement`).

## L18. Non-reproducible emit — the same source compiles to two different outputs across runs (LIVE, measured 2026-09-12)

**Problem:** compiling `src/test/corpus/programs/750-objectKeysValues.ms` repeatedly with ONE binary, each
run in a fresh working directory, yields two distinct outputs. On the JS target variant A is 3805 lines
and variant B 3565: A additionally emits monomorphized std instances that the program never calls
(`Map_get`/`Map_set`/`mapEndWrite`/`orderedMap*` over `<number, string>` and `<k46, string>`, and
`pop<ref Node>`), i.e. instances requested while the `Object.keys` / `Object.values` macros were
evaluated leak into the user program's instance set. On C the visible difference is one temp name in
the `dup<string>` instance (`$borrow_3` vs `$borrow_2`) — the extra instances are dead there but shift
the temp counter. Both variants run correctly; the output is simply not reproducible.

**Measured (8 consecutive runs, alternating two binaries, both at main `28a78982`, the installed
`msc` as control):** `ctl:A ctl:B cand:A cand:B ctl:A cand:A cand:A cand:A`. Control alone over 12 C runs
happened to be stable (all `$borrow_3`); over 4 JS runs it was not (first A, then B ×3). A build at
`-O0` with the slab allocator on gave 6/6 identical, a build under ASan with `-DMS_SLAB_MAX=0` gave 4/4
identical and no report, a `-O3` build with the slab off gave 1 A / 5 B. So it is not the width-band
change of the same day, not a slab-recycling artefact, and ASan sees nothing — the trigger is
untraced. The program uses comptime macros deferred to monomorphization; programs without macros
(the other 191 corpus entries) emitted identically across the whole 2026-09-12 emit-diff run.

**Why it matters:** an emit-diff gate or a fixpoint comparison can report a phantom difference (this
is the shape of the gen-2 anomaly recorded on 2026-09-12 in the `typeFlags` arc, where a `--danger`
build once dropped two null checks and could not be reproduced). Treat a single-run difference in a
macro-using program as suspect until re-emitted.

**Not verified:** which pass registers the leaked instances, whether the prelude pack (`.pk`, keyed by
tool stamp ‖ std tree hash) is on the path, and whether the C-side `$borrow` shift can ever change
semantics rather than names.

## L19. ~~Comptime engine evaluates bitwise operators at 32 bits~~ (FIXED on the candidate, 2026-09-12)

**Was:** every bitwise opcode of the Raiser VM narrowed both operands with `as int32`, so a shift
by 32 or more wrapped modulo 32 at comptime while the C/JS backends gave `int64`/`uint64` operands
64-bit semantics. Visible through `BitSet<E>` past 32 members: `(E.M39 | E.M1).has(E.M7)` was
`true` in a macro and `false` at run time.

**Fix (tracks the reference VM):** `RaiserValue.intVal` is an `int64` register (29 sites, 6 files),
the bitwise opcodes operate on the full width, and the engine codegen narrows the way the reference
`genNarrow` does: the shift count is taken modulo the operand width, a `<<` result is sign-extended
(signed) or masked (unsigned) to its width, `~` on an unsigned type is masked, and `>>` on an
unsigned type narrows the left operand and shifts logically (`ShiftRightU`); signed `>>` stays
arithmetic. Three opcodes appended: `NarrowU`, `SignExtend`, `ShiftRightU`.

**Measured on the candidate**, comptime | runtime:

```
shl(1, 39) on int64                          549755813888 | 549755813888   (was 128 at comptime)
shl(1, 31) / shl(1, 39) on int32             -2147483648 128               (C debug panics on 1 << 31)
~5 on uint8 / shl(3, 31) on uint32           250 2147483648 | 250 2147483648
shr(shl(1, 63), 63) on uint64                1 | 1                          (was 18446744073709551615 before ShiftRightU)
(M39 | M1).has(M7), has(M39), == (M7 | M1)   false,true,false | false,true,false
```

Not narrowed, on purpose for now: `+ - *` results (the reference narrows those too via
`genBinaryABCnarrow`); the engine has never narrowed them and no set path depends on it.

## L20. Comptime engine multiplies a bridge-returned float as an integer (FIXED, re-measured 2026-09-16)

```
import { Node, NodeKind, floatValue } from "std/meta";
macro fm(v: Node): Node {
	const f = floatValue(v);
	const a = f * 2.0; const b = 2.0 * f; const c = f + 0.25; const d = f * 2; const e = 0.5 * 2.0; const g = f / 2.0;
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column, value: a.toString() + "," + b.toString() + "," + c.toString() + "," + d.toString() + "," + e.toString() + "," + g.toString() };
}
console.log(fm(0.5));      // 0,0,0.75,0,1,0   — expected 1,1,0.75,1,1,0.25
```

`+` on the same value is right, `*` and `/` are not, and `*` on two literals is right: the engine
codegen picks the float opcode from a static "this register holds a float" mark (`isRegFloat`), which
a literal gets and a value returned by a host bridge does not, so the product goes through `MulI64`
on the zero `intVal`. Present on every binary tried (5c21d90a, 789941c7, the candidate). Raiser
tier, unrelated to sets; the reference VM dispatches float arithmetic on the operand TYPE (`vmgen`
`mMulF64`), not on a register mark.

**FIXED — the repro above was re-run verbatim on 2026-09-16** (installed `msc` v0.2.54, tip `3dfadbb9`):
it now prints `L20 repro: 1,1,0.75,1,1,0.25` against `expected : 1,1,0.75,1,1,0.25`. The register mark the
entry blames is gone from the source (`git grep isRegFloat` = 0 hits); the arithmetic and comparison arms
read the operand type. Pinned by `src/test/fixedbugs/bug165FloatArithInEngine.ms` (8 tests) and corpus
`776-macroFloatArith.ms`. NOT verified here: only this repro shape was re-run — the neighbouring comptime
math gaps (`%` on floats, `**`, `Math.*`) are still open and measured separately.


## L21. A `BitSet<E>` as an array element, a generic type argument, or a nullable payload does not compile on C (FIXED; corpus `772-bitSetSlots` passes on C and JS with the installed `v0.2.54`, 2026-09-15)

Measured on the installed binary (`ac997a5e`, gen-2 `--danger`); JS was right in every cell.
Four dispatches on `TypeKind` had an arm for the sibling kinds and none for `Set`:

```
const arr: BitSet<E>[] = [s]; arr[0].has(E.A)          C: msRefArray, clang "assigning to 'void *' from 'uint8_t'"
                                                        — elemArrayCName (codegen/c/types.ms) has no Set arm
const b: Box<BitSet<E>> = new Box(s); b.v.has(E.C)       "unknown is not assignable to BitSet<E>"; b.get() is Inferred
new HashMap<string, BitSet<E> >().set("k", s)            "in instantiation of 'set<string, <inferring>>': … memory layout differs"
                                                        — monoConcreteTypeName (monomorphize/clone.ms) spells a Set as "unknown";
                                                          injectConcreteTypeSyms (checker/instantiate.ms) does not inject the element enum
function pick(on: boolean): BitSet<E> | null            C: "returning 'uint8_t' from a function with incompatible result type 'msUnion_…'"
                                                        — isMaybeWrappable (checker/types.ms) returns false for Set, so the slot is a raw union
same on JS, through the build path                       prints `true,false`: the absent case reads as present
                                                        — unwrapMaybe (transform/native/maybeUnwrap.ms) collapses x.value → x but leaves the
                                                          Maybe type on the node, and lowerBitSet runs after it
```

Candidate (5 arms, 11 lines): every probe C = JS; corpus lanes `bitSet`
42/0, `null` 12/12, `maybe` 12/12, `matchArm` 6/0. Struct/interface fields, generic functions,
cross-module enums, closures and the 64-bit band with `0 as BitSet` were already right on both
backends.

## L21b. The set algebra was missing its difference, subset and cardinality (FIXED; corpus `773-bitSetAlgebra` passes on C and JS with the installed `v0.2.54`, 2026-09-15)

`docs/LANG-PRIMITIVE.md` told readers to write `a & ~b` for the difference. Measured: `~a` on a
set falls through to the integer rule and yields `int32`, so `a & ~b` reports
`bitwise operator '&' on 'BitSet<E>' and 'int32' mixes different enum sets`, and there was no
other spelling for the difference. Subset and cardinality had none either.

Now eight methods named as ES2025 names them on `Set`, all bodiless `@builtin` declarations in
both prelude overlays, all lowered to the reference's own expressions. `~a` is rejected with a
message that says what to use instead. Table, lowering and measurements: `docs/LANG-PRIMITIVE.md`.

## L21c. A value-typed receiver bound to the `unknown` extension catch-all (FIXED; two equal sets hash equally on C with the installed `v0.2.54`, 2026-09-15)

`hash()` takes no argument, so overload scoring cannot separate the five `hash` declarations in
the prelude and the catch-all `hash(this u: unknown)` won for any receiver with no exact match.
For a value type that meant hashing the ADDRESS: two sets equal by value hashed differently and
every `HashMap<BitSet<E>, V>` lookup missed silently while `size` still counted the inserts. The
emitted C showed it plainly as `hash__…_u3(&s)`.

The same rule already applied to an `unknown` PARAMETER (`isPointerShapedForUnknown`, the error
`cannot pass value type … as unknown — no void* representation`); it now applies to an extension
RECEIVER too, and only when another candidate remains, so every single-candidate call is
unchanged. Structs are still hashed by address where no better candidate exists.

## L22. `new X<A<B>>` — a `>>` closing two type-argument lists types the instance as `Inferred` (LIVE, measured 2026-09-13)

```
class Box<T> { v: T; constructor(v: T) { this.v = v; } get(): T { return this.v; } }
const x = new Box<Array<E>>([E.A]);      internal: unresolved type (kind=48) reached codegen   (48 = Inferred)
const x = new Box<Array<E> >([E.A]);     1,true   — a space between the two '>' makes it right, C and JS
const r = id<BitSet<E>>(s);              right    — the CALL form already splits the token
```

Fail-open: no checker error, the instance is `Inferred` until codegen. Same for `Box<BitSet<E>>`
and `HashMap<string, BitSet<E>>`. Parser-side; nothing to do with sets.

## L23. An array of sized arrays is emitted as `msRefArray` on C (LIVE, measured 2026-09-13)

```
struct P { a: uint8[3]; }
const arr: uint8[3][] = [p.a];  arr[0][1]
C:  "assigning to 'void *' from incompatible type 'msSizedArray_uint8_t_3'"
JS: 2,1
```

`elemArrayCName` has no `SizedArray` arm either — the same second naming path as L21's first
cell. The array band of a set (`BitSet<E100>[]`) inherits it.

## L24. Compound bitwise assignment `|=` / `&=` / `^=` / `<<=` does not lex (LIVE, measured 2026-09-13)

```
let x: int32 = 3;
x |= 4;  x &= 1;  x ^= 1;  x <<= 1;     error: Parse: Unexpected token: = at line 2   (each, both backends)
x += 1;                                 4
```

`>>=` and `-=` not measured. No token for the bitwise forms in `src/lexer/token.ms`.

## L25. ~~`HashMap` is not defined on the JS backend~~ RETRACTED 2026-09-13 — it was the `msc run --target=js` path

The first probe used `msc run --target=js` and reported `ReferenceError: HashMap is not defined`.
That is the tree-mode emit path, which is separately broken, and the same command fails the same
way on corpus `504-hashContainers` with the INSTALLED compiler. Through the build path the
container works on both backends:

```
msc build m.ms --target=js && node m.js      2,first,true      (HashMap<BitSet<E>, string>)
msc run  m.ms --target=js                    ReferenceError: HashMap is not defined
corpus lane 504-hashContainers [js]          exit=0
```

Kept as a numbered entry because the retraction is the useful record: a single-variant probe on a
known-broken path produced a confident wrong claim about a whole backend surface.

## L26. An enum member literal bound as a generic parameter is passed as `unknown` (LIVE, measured 2026-09-13)

```
function keep<T>(x: T): T { const y: T = x; return y; }
keep(E.B)                 "cannot pass value type E.B as unknown — no void* representation"
const e: E = E.B; keep(e) true    — a variable typed by the enum is right
keep(7); keep([1, 2])     right
```

The inferred `T` is the `EnumLiteral` kind, which `injectConcreteTypeSyms` does not know, so the
body's `T` re-resolves to `unknown`. Belongs to the generic argument-fit list.

## L27. A default (`-O0`) gen-1 build of the compiler segfaults checking or testing the compiler (LIVE, measured 2026-09-13)

```
msc build src/index.ms --gc=drc --output=msc-x          rc 0
./msc-x check src/index.ms                             rc 139, deterministic (3 runs), stack 8 MB (hard limit, cannot be raised)
./msc-x check src/compiler/compile.ms                  rc 139
./msc-x check src/checker/types.ms                     OK 53 modules
./msc-x test src/test/c/bitSetWidth.ms                 rc 139
installed msc (gen-2 --danger) check src/index.ms      OK 337 modules
```

Reproduced from source `ac997a5e` (built by the installed msc) and from `789941c7` (built by the
matching backup `msc.bak-20260912-222201`), inside and outside the tool sandbox. Earlier gate
logs for the same `789941c7` source record `CHECK rc=0` with a gen-1 binary built the same way,
so an unidentified variable is involved. Not bisected; no backtrace taken yet.

**Corroborated 2026-09-13 on a different lane and a third source tree**, one variable changed per
cell: `msc test src/compiler/meta/decorators.ms` (78 files / 1941 tests) exits 139 with a
**zero-byte** log under a `-O0` binary — both when that binary was built from a modified tree and
when it was built from pristine `b07a547f` — while the same lane under a `--danger` binary passes
1941/1941 against either tree. Small lanes stay green on the very same `-O0` binary
(`src/utils/string.ms` 353 tests, `src/checker/symbol.ms` 450), so the trigger scales with lane
size, which fits the 8 MB stack ceiling noted above. Still not bisected, still no backtrace.

## L28. The JS backend cannot run a subclass declared before its parent (LIVE, measured 2026-09-13)

```
class K extends P { y: int32 = 2; }
class P { x: int32 = 1; }
main();            C  (msc run):     1 2
                   JS (--target=js): ReferenceError: Cannot access 'P__…' before initialization
```

Classes are emitted in source order, so `class K extends P` reads `P`'s binding inside its own
temporal dead zone and node throws while loading the bundle. The checker accepts the order — C has
no such constraint and runs it — so the program type-checks clean and dies on one backend only.
Measured on the decorator-free program above, built by a pristine-HEAD binary: nothing to do with
decorators, macros or metadata. Consequence for tests: a guard needing this shape must not carry
`// GUARD-JS` (see `src/test/guard/decoratorMetadataInheritOrder.ms`). Not investigated further —
no fix attempted, and it is unknown whether hoisting class declarations is safe for the emitter.

Re-measured 2026-09-19 on a build of `98886eb2`, with statics on both classes:

```
function seven(): int32 { return 7; }
class Child extends Base { static c: int32 = seven() + 1; }
class Base { static b: int32 = seven(); }
console.log(`${Child.c} ${Base.b}`);
    C:  8 7
    JS: ReferenceError: Cannot access 'Base__…' before initialization
```

## L29. A class cannot extend a class imported from another module (LIVE, measured 2026-09-13)

```
// lib.ms
export class P { x: int32 = 1; }
// use.ms
import { P } from "./lib";
class K extends P { y: int32 = 2; }

msc run use.ms → cannot declare 'P_init': the parent constructor signature is not reachable from this module
```

Fails at check, before codegen, on the plain shape with no decorators anywhere; the identical two
classes in one file compile and run. This bounds every feature that resolves through the
inheritance chain — decorator metadata inheritance is same-module only for this reason, not by
design. Root cause not investigated.

## L30. An actor with no methods emits a call to an undefined `<Actor>_dispatch` (LIVE, measured 2026-09-13)

```ms
actor Srv { n: int32 = 1; }
const s = new Srv();

msc run f.ms → error: use of undeclared identifier 'Srv_dispatch'
  (s__…->pid = msActorCreatePid(s__…, Srv_dispatch));
```

Trigger boundary: the actor declares **zero methods**. Adding any method to the same actor makes the
program compile and run, so the shape — not the field — is what fails; `readonly` is irrelevant, a
plain `n: int32 = 1` field fails identically. Constructor lowering emits `msActorCreatePid(self,
<Actor>_dispatch)` unconditionally while the dispatch function is only emitted for an actor that has
messages to dispatch. Every guard and corpus program gives its actors methods, which is why no lane
covers this shape. The failure reproduces on the published compiler as well, so it is not a
regression from recent checker work. Root cause not investigated.

## ~~L31. A `static` field on an actor reads back as `<object>`~~ (RESOLVED, measured 2026-09-19)

An actor static must now be `static readonly` (a plain `static` is a check error naming the fix,
`51832817`). The readonly form reads back on both backends, on a build of `98886eb2`:

```ms
actor Srv { static readonly tag: string = "t-init"; n: int32 = 1; ping(): int32 { return 1; } }
console.log(Srv.tag);            // C: t-init   JS: t-init
```

The historical entry follows.

```ms
actor Srv { static tag: string = "t-init"; n: int32 = 1; }
console.log(Srv.tag);            // prints: <object>

class K { static tag: string = "t-init"; n: int32 = 1; }
console.log(K.tag);              // prints: t-init
```

The identical static field on a plain class reads back correctly, so this is actor-specific rather
than a static-field defect. It is independent of decorators (the same actor without any prints
`<object>` too) and of the compiler generation (the published binary prints `<object>` as well). The
declaration parses and the read type-checks clean, so the value is only lost at runtime. Root cause
not investigated.

## L32. Implicit text conversion of a `BitSet<E>` fails the C compile (LIVE, measured 2026-09-15)

```
const s: BitSet<Mod> = Mod.ThickHide | Mod.Pacifist;          installed v0.2.54, 6-member enum
console.log(`t ${s}`);      C: clang "member reference base type 'uint8_t' is not a structure or union"
                                (emitted `s_1_.toString()`)                                 JS: t 12
console.log("c " + s);      C: clang error                                                   JS: c 12
console.log(String(s));     C: clang error                                                   JS: 12
console.log(s);             C: <BitSet>                                                      JS: 12
s.toString()                {ThickHide, Pacifist} on both, alone and inside `${…}`, `+` and `+=`
```

The implicit sites reach the prelude's `toString<E>(this self: BitSet<E>)` on neither backend: C
emits a struct member call on the representation word, JS prints the word. The explicit call
resolves on both.

## L33. A generic class loses its field initializers (LIVE, measured 2026-09-16)

```
class Box<T> { count: int32 = 21; v: T; constructor(v: T) { this.v = v; } }
console.log(new Box<int32>(1).count);        tip 3dfadbb9, --gc=drc: 0   (expected 21)
```

Same shape without the type parameter prints 21. No import, no macro, no decorator involved.
Re-measured 2026-09-19 on a build of `98886eb2`: C prints `0`, JS prints `21`.

## L34. A generic class with a `T[]` field crashes on first use (LIVE, measured 2026-09-16)

```
class Bag<T> { items: T[] = []; add(x: T): void { this.items.push(x); } }
const g = new Bag<int32>(); g.add(1);
    tip 3dfadbb9, --gc=drc: panic "member access within null pointer of type 'int32_tArray'"
    in Bag_add__int32, rc=255
```

The `[]` initializer never reaches the instance: the field is NULL when `add` runs. Likely the
same missing-initializer path as L33, seen through a pointer instead of a value.
Re-measured 2026-09-19 on a build of `98886eb2`: C panics as above, JS prints `1` for
`g.items.length`.

## L35. `await` inside a string concatenation reaches C codegen unlowered (LIVE, measured 2026-09-16)

```
async function f(): Promise<string> { return "x"; }
async function main(): Promise<void> { console.log("a" + await f() + "b"); }
await main();
    tip 3dfadbb9: clang "expected expression" on
    `_mscc1_[1] = /* unsupported expression: kind=YieldExpr */;`
```

`const s = await f(); console.log("a" + s + "b");` compiles and runs. The await lowering handles
the statement position but not an operand inside the concat-array fill the string `+` chain
emits. Re-measured 2026-09-19 on a build of `98886eb2`: the template form
`` console.log(`a${await f()}b`) `` fails identically on C; both forms print `axb` on JS.

## L36. A method of a function-body class cannot read the enclosing function's locals on C (LIVE, measured 2026-09-19)

```
function local(n: int32): int32 {
	const k: int32 = n * 2;
	class L { get(): int32 { return k; } static sget(): int32 { return k; } }
	return new L().get() + L.sget();
}
console.log(`${local(1)}`);
    build of 98886eb2, C:  clang "use of undeclared identifier 'k'" (both methods)
                       JS: 4
```

Instance and static methods fail alike. The checker accepts the read; C lifts the methods to
module-level functions that have no access to `k`. A static *initializer* reading an enclosing
local is a check error (`1c7b6c7b`); methods have no such rule and no capture.

## L37. A module-level `let` written from an actor method is not rejected (LIVE, measured 2026-09-19)

```
let hits: int32 = 0;
actor Counter { bump(): void { hits = hits + 1; } read(): int32 { return hits; } }
// main: c.bump(); c.bump(); console.log(await c.read());
    build of 98886eb2, C: 2   JS: 2
```

The program runs, but the global is shared by every actor thread with no lock. `SymbolFlag.GcSafe`
is declared in `std/meta/node.ms` but nothing under `src/` or `std/` sets or reads it, so no rule
tracks which functions touch mutable globals. Only the actor-method write was measured; `spawn` bodies were not.

## L38. A static written through a subclass name diverges between backends (LIVE, measured 2026-09-19)

```
class K { static a: int32 = 1; }
class Sub extends K {}
Sub.a = 5;
console.log(`${K.a} ${Sub.a}`);
    build of 98886eb2, C: 5 5   JS: 1 5
```

C resolves `Sub.a` to `K`'s global; JS creates an own property on `Sub`. Silent: both type-check
and run. `this` in a static method is the declaring class on both backends (a static method is
emitted as a free function on both), so `Sub.bump()` writing `this.a` gives the C answer on both;
TypeScript would bind `this` to `Sub`. Pinned by `src/test/guard/staticThis.ms`.

## L39. A static method on an actor does not compile on C (LIVE, measured 2026-09-19)

```
actor A {
	static readonly limit: int32 = 4;
	static twice(): int32 { return A.limit * 2; }
}
console.log(`${A.twice()}`);
    build of 98886eb2, C:  clang "use of undeclared identifier 'this'" in the body,
                           and "passing 'msFuture_int32 *' … to parameter of incompatible type 'double'"
                       JS: 8
```

The static method is lowered like a message handler: its body reads the receiver and its call
returns a future. The same failure with `this.limit` in place of `A.limit`.

## L40. A static getter is not found (LIVE, measured 2026-09-19)

```
class K { static a: int32 = 6; static get doubled(): int32 { return K.a * 2; } }
console.log(`${K.doubled}`);
    build of 98886eb2, C and JS: Property 'doubled' does not exist on type 'K'
```

Fails at check on both backends. Static setters were not measured.

## L41. `this` in a generic static method is undefined (LIVE, measured 2026-09-19)

```
class K { static a: int32 = 1; static pick<T>(x: T): T { this.a = this.a + 1; return x; } }
    build of 98886eb2, C and JS: Undefined variable 'this'
```

`this` in a non-generic static method, a `static { }` block and a static initializer names the
class (`daa8a3c5`). A generic method body is checked again per instantiation, and that check
does not know which class owns the method. Writing `K.a` instead works on both backends (`x 2`).

## L42. A static field of a generic class does not link on C (LIVE, measured 2026-09-19)

```
class G<T> { static a: int32 = 4; v: T; constructor(v: T) { this.v = v; } }
console.log(`${G.a}`);
    build of 98886eb2, C:  link failed, undefined symbol: _G__a
                       JS: 4
```

## L43. A static field of an imported class is rejected (LIVE, measured 2026-09-19)

```
// implib.ms
export class P { static a: int32 = 9; static twice(): int32 { return P.a * 2; } }
// use.ms
import { P } from "./implib";
console.log(`${P.a}`);        build of 98886eb2, C and JS: Property 'a' does not exist on type 'P'
console.log(`${P.twice()}`);  build of 98886eb2, C and JS: 18
```

The static method crosses the module boundary; the static field does not.

## L44. `Locked<T>` does not exist on the JS backend (LIVE, measured 2026-09-19)

```
actor A { static readonly box: Locked<int32> = new Locked<int32>(3); ping(): int32 { return 1; } }
    build of 98886eb2, C:  runs
                       JS: ReferenceError: Locked is not defined
```

`src/test/guard/actorStaticLocked.ms` is a C-only guard for this reason. `Arc<T>` on JS was not
measured.

## L45. Two corpus programs fail inside a macro body (LIVE, measured 2026-09-19)

```
704-macroExprHoist   Macro 'memo' body: Type 'NodeFlag' is not assignable to type 'BitSet<NodeFlag>'
762-bitSetMacro      Macro 'inMacro' body: Type 'int32' is not assignable to type 'Node' …
```

Both fail to build on a build of `98886eb2` and on the installed `v0.2.55`; they are listed in
`src/test/known-red.json` on every lane. Root cause not investigated.

A class declared in the body of a generic function (`function wrap<T>(x: T) { class L { static a
= 5; } return L.a; }`) was measured on the same build and prints `5` on C and JS; other shapes of
that case were not measured.

## L46. A module-level destructuring binding read inside a closure is empty on C (LIVE, measured 2026-09-19)

```ms
const pair: [string, string] = ["p", "q"];
const [a, b] = pair;
function run(f: () => void): void { f(); }
function main(): void { run(() => { console.log("a=" + a + " b=" + b); }); }
main();

C:  a= b=          JS: a=p b=q
```

The emitted C declares the bindings as module statics and assigns them in `__Init000`
(`static msString a; … a = dollarborrow_1_;`), but the closure captures them as if they were
locals of the enclosing function: the env struct carries `msString a; msString b;` fields, the
lifted body reads `env->a`, and the caller only allocates the env — it never writes those fields,
so the closure reads zeroed memory.

| shape (module level unless stated) | C | JS |
|---|---|---|
| `const [a, b] = pair` of `string`, read in a closure | `a= b=` | `a=p b=q` |
| the same of `int32` | `a=0 b=0` | `a=7 b=9` |
| the binding is an accessor (`const [x, setX] = createSignal("v")`), read in a closure | SIGSEGV, `EXC_BAD_ACCESS address=0x0`, no frames | correct |
| the same accessor read in a `test` block instead of a program | assertion fails, value empty | — |
| `const { p, q } = rec` (object pattern) with or without a closure | clang: `initializer element is not a compile-time constant` | `p=p q=q` |
| the same tuple read directly, no closure | correct | correct |
| `const s = createSignal("v")` with `s[0]()` — no destructuring | correct | correct |
| the whole shape inside a function instead of module level | correct | correct |

Measured on a build of `660f3002` + two uncommitted fixes and on the installed `v0.2.55`, so it
predates both. Found from Neon, where `const [count, setCount] = createSignal(0)` at module level
is the ordinary idiom: every such program dies at the first closure that reads the accessor. The
Neon suite does not see it because each test declares its signals inside the test block.

Not measured: a destructured `let`, patterns with a default or a rest element, a struct or array
element type, capture depth beyond one closure, and whether `--release` changes the C shape.

## L47. The narrowing of a `const` does not survive into a closure (LIVE, measured 2026-09-19)

```ms
function run(h: ((n: number) => void) | null, s: string | null): void {
	const g = h;
	if (g !== null) { g(1); const k = (): void => { g(2); }; k(); }
	const t = s;
	if (t !== null) { const len = (): number => t.length; console.log(len()); }
}

both backends: callee is possibly null (function | null) — unwrap with '!' or a null check first
              Property 'length' does not exist on type 'Maybe_p1'. Available: value, present
```

The same `if` body without the closure compiles and runs (`g(1)` alone prints `n=1` on C and JS),
so the narrowing holds until a function expression reads the binding. The flow walk stops at the
closure's flow container instead of continuing into the enclosing flow, and a `const` can never be
reassigned, so the narrowing it carries is still valid there.

Measured on the installed `v0.2.55`, native and `--target=js`, standalone (no imports). Costs Neon
a conditional nullable handler: the wrapper that unwraps the text of `onChangeText` is a closure
over the narrowed temp, so `direct` rejects a nullable handler outright and two fixtures pin that
rejection. Not measured: a narrowed parameter, a `let` that is never reassigned, narrowing by
`typeof` or by a discriminant rather than `!== null`, and a closure nested two levels deep.
