# C Codegen Gap Analysis

Gaps between our C codegen (~3.2K lines, 9 files) and a production-grade C backend (~10K lines).
Each item: what's missing, why production compilers have it, why we don't yet, how to close.

---

## Summary Table

| # | Gap | Severity | Effort | Blocked? |
|---|-----|----------|--------|----------|
| 1 | ~~Generic monomorphization~~ | ~~DONE~~ | ~~1560 lines~~ | ~~Completed~~ |
| 2 | ~~Pointer accessor (-> vs .)~~ | ~~DONE~~ | ~~86 lines~~ | ~~Completed~~ |
| 3 | @builtin expansion | Blocking | ~200 lines | No |
| 4 | ~~std/core.ms auto-import~~ | ~~DONE~~ | ~~~230 lines~~ | ~~Completed~~ |
| 5 | RTTI / type info | N/A | 0 lines | Intentionally omitted (static type system) |
| 6 | Bounds checking | Functional | ~20-100 lines | No |
| 7 | Overflow checking | Functional | ~80 lines | No |
| 8 | String concat optimization | Functional | ~80 lines | No |
| 9 | ~~Missing expression kinds~~ | ~~DONE~~ | ~~All 15 kinds~~ | ~~Completed~~ |
| 10 | Inline arithmetic magic | Optimization | ~30 lines | No |
| 11 | Sequence construction | Optimization | ~90 lines | No |
| 12 | NRVO | Optimization | ~100 lines | No |
| 13 | Multi-module C output | Deferred | ~200 lines | Needs multi-module checker |
| 14 | Write barriers | N/A | 0 lines | Intentionally omitted (DRC) |
| 15 | ~~Move marker → DRC~~ | ~~DONE~~ | ~~200 lines~~ | ~~Completed~~ |
| 16 | ~~Lambda lifting all FunctionExpr~~ | ~~DONE~~ | ~~482 lines~~ | ~~Completed~~ |
| 17 | openArray (ptr, len) convention | Functional | ~200 lines | Needs runtime array struct |
| 18 | JS string encoding (UTF-8 vs UTF-16) | JS Backend | ~200 lines | No |
| 19 | String/Array runtime architecture | Tracking | — | See [LANG-RUNTIME.md](LANG-RUNTIME.md) |
| 20 | JS performance & bundle optimization | JS Backend | ~350 lines | No |
| 21 | Default parameter limitations | Edge Case | ~100 lines | No |


## Blockings

### 1. ~~Generic Monomorphization~~

**Status: DONE.** Full monomorphization pipeline implemented in `src/monomorphize/`:

1. **Generic functions**: `collect.ms` (~1360 lines) — collects generic definitions, discovers call sites, clones AST with type substitution (fixed-point instantiation loop for nested generics), re-type-checks bodies, rewrites call sites to mangled names (e.g., `id__number`, `id__string`)
2. **Generic types**: `collect.ms` — reads GenericTypeInstStore (checker-populated), creates concrete InterfaceDecl nodes with substituted fields (e.g., `Box__number { value: number }`)
3. **Registry**: `registry.ms` (~200 lines) — instantiation tracking, deduplication, mangled name generation
4. **Codegen**: Fully generic-unaware. Receives only concrete FunctionDecl/InterfaceDecl nodes — zero generic handling needed.

Pipeline: `parse → check → **monomorphize** → transform → analyze → codegen`

---

### 2. ~~Pointer Accessor (-> vs .)~~

**Status: DONE.** Full Nim-parity `nkHiddenDeref` architecture implemented:

1. **nodeType annotation**: `checkExpr()` stores resolved `Type` on every expression node via `node.nodeType` (checkExprPass.ms:155). Field is `nodeType: Type` on Node interface — proper typed pointer (upgraded from `unknown`/`void*`).
2. **HiddenDeref NodeKind**: Dedicated AST node (like Nim's `nkHiddenDeref`). Reuses `{ expr: Node }` shape — no new union variant needed.
3. **Checker insertion**: `checkMemberExpr()` calls `isPointerInC(objType, ctx)` — checks class/ref/ptr types. Wraps `d.object` in HiddenDeref node (checkExprPass.ms:278-282).
4. **Codegen**: `genHiddenDeref()` emits `(*expr)` (expressions.ms:143-148). `genMemberExpr` keeps `.` — correct for `(*ptr).field`.
5. **Full pipeline**: walker, printer, monomorphize clone all handle HiddenDeref.

Result: `obj.field` where obj is a class → `(*obj).field` in C (equivalent to `obj->field`).

---

### 3. Builtin Inline Expansion (@builtin stub)

**Gap**: `lowerBuiltinCall` in builtinLower.ms:143 is a pass-through stub. `@builtin("Print")` calls a nonexistent `Print` function instead of `ms_print(...)`.

**Why production compilers have it**: Builtins (print, string length, array push) are the most-called operations. Production compilers expand 70+ magic operations inline — `mLengthStr` → `x->len`, `mConStrStr` → pre-allocated concat, `mAppendSeqElem` → resize + assign. Without expansion, no standard library works.

**Why we don't**: We designed builtinLower as a pre-codegen transform (cleaner separation), but haven't filled in the actual rewrite rules yet. The `@runtime("c_name")` path works — `@builtin` doesn't.

**How to close**:
Add match arms in `lowerBuiltinCall` for each builtin kind:
- `"Print"` → rewrite to `ms_print(args...)`
- `"LengthStr"` → rewrite to `ms_string_length(arg)`
- `"LengthArr"` → rewrite to `ms_array_length(arg)`
- etc. ~15-20 builtins initially, ~200 lines.

---

### 4. ~~std/core.ms Auto-Import~~

**Status: DONE.** Full prelude → C runtime pipeline implemented:

1. **Prelude file**: `std/core.ms` with `@runtime("c_name")` annotated class methods (e.g., `console.log → ms_println`)
2. **Loading**: `checkProgram()` calls `globalImports()`, reads `std/core.ms` from disk, parses + runs 3 passes in Global scope before user code
3. **Decorator plumbing**: collectPass extracts `@runtime` metadata via `extractDecoratorInfo()`, sets `fnType.typeName`; resolvePass preserves it from oldType
4. **Codegen dispatch**: `genCallExpr` unwraps HiddenDeref, looks up class symbol + method type, emits `typeName(args)` directly (no mangling)
5. **C runtime**: `runtime/runtime.h` (declarations) + `runtime/io.c` (implementations), wired into clang via `cc.ms` `resolveRuntime()`
6. **Live file**: Changes to `std/core.ms` take effect without compiler rebuild

Result: `console.log("hello world")` → `ms_println("hello world")` end-to-end.

---

## Functional

### 5. RTTI / Type Info Tables

**Status: NOT NEEDED (intentional design).**

MetaScript's architecture eliminates all use cases that require RTTI:

- **Exception handling**: Untyped catch-all via setjmp/longjmp. Parser accepts `catch (e: Type)` but **discards the type annotation** (`skipOptionalType` in errorHandling.ms). TryCatchStmtData has no `catchType` field.
- **No `instanceof`/`is` operator**: No runtime type test exists in lexer, parser, or checker.
- **No virtual dispatch**: `extends` is parsed but checker ignores it — no method overriding, no vtables, no polymorphic call sites.
- **No tracing GC**: Deterministic RC (Phase 4 DRC) handles all lifetime statically — no type info needed for collection or cycle detection.
- **Generics monomorphized**: Compile-time specialization, zero runtime generic dispatch.

**Revisit only if MetaScript adds**: typed exception filtering (`catch (e: FileError)`), virtual method dispatch, reflection API, or tracing GC.

---

### 6. Bounds Checking

**Gap**: `arr[i]` emits `arr[i]` — no validation that `i < arr.length`. Out-of-bounds = silent memory corruption.

**Why production compilers have it**: Buffer overflows are the #1 security vulnerability in C. Production compilers emit `if (i >= len) raiseIndexError()` before every array/string access. Optional via compiler flag for release builds.

**Why we don't**: Codegen is "dumb" by design — emits what it sees. Bounds checks are a semantic addition the AST doesn't contain. Could be injected by analyzer (Phase 4) or emitted inline by codegen.

**How to close**:
Option A (analyzer): Inject `if (i >= len) ms_raise_index(i, len)` before every ArrayAccess in Phase 4. ~100 lines in inject.ms.
Option B (codegen): In `genArrayAccess`, emit bounds check inline. ~20 lines in expressions.ms. Needs compiler flag to disable.

---

### 7. Overflow Checking

**Gap**: `a + b` for integers emits `(a + b)` — silent wraparound on overflow.

**Why production compilers have it**: Integer overflow causes undefined behavior in C (signed) or silent wraparound (unsigned). Production compilers emit `nimAddInt64(a, b)` which checks and raises on overflow. Critical for financial/crypto code.

**Why we don't**: Our `genBinaryExpr` maps operators 1:1 to C operators. No type awareness — doesn't know if operands are int32 (needs overflow check) or float64 (no overflow).

**How to close**:
In `genBinaryExpr`, check operand types. For integer arithmetic (`+`, `-`, `*`), emit `ms_addInt32(a, b)` instead of `(a + b)`. Runtime function checks `__builtin_add_overflow`. ~50 lines in expressions.ms + ~30 lines runtime.

---

### 8. String Concat Optimization

**Gap**: `a + b + c` for strings becomes nested function calls: `ms_concat(ms_concat(a, b), c)` — allocates intermediate strings.

**Why production compilers have it**: String concatenation is hot code. Production compilers detect chains, pre-calculate total length (`a.len + b.len + c.len`), allocate once, memcpy segments. 2-3x faster, zero intermediate allocations.

**Why we don't**: builtinLower rewrites string `+` to `ms_concat(a, b)` per pair. No chain detection.

**How to close**:
Add concat chain detection in builtinLower: walk nested `BinaryExpr(+)` trees with string operands, collect all segments, emit `ms_concat_N(seg1, seg2, ..., segN)` or `ms_concat_buf(buf, segments[], count)`. ~80 lines in builtinLower.

---

### 9. ~~Missing Expression Kinds~~ — DONE (5/5 correct)

Phase 3 native-backend transforms (`transform/native/`) + C codegen handlers implemented. All expression kinds now at production parity.

**UpdateExpr — CORRECT.** Phase 3 lowers statement-position `i++` → `i = i + 1`. Expression-position `i++`/`++i` survives to codegen, maps 1:1 to C. Production compilers don't have `++`/`--` (they use `inc(x)`/`dec(x)` as void magic ops emitting `x += 1`). Different syntax, same semantics. Overflow checking on increment is Gap #7, not a concern here.

**NewExpr — ACCEPTABLE, architectural debt.** `newExprLower.ms` lowers `new Foo(args)` → `Foo_new(args)`. Production compilers keep `new` in codegen because: (1) GC-specific dispatch — 4 different allocation paths depending on memory model, (2) type info generated lazily during codegen, intertwined with module state, (3) `sizeof(T)` is a C-level op that transforms can't compute. Our approach works because we have no polymorphic interfaces (no `m_type`), deterministic RC only (no GC mode selection), and constructor functions bake in size. **Loses**: inline sizeof, type info at call site, write-barrier selection. Revisit if we add class inheritance or cycle-aware GC.

~~**MoveExpr — DONE (Gap 15).**~~ MoveExpr survives to Phase 4 (analyzer) where DRC handles it: forces sink semantics, emits `wasMoved`, produces `errFailedMove` diagnostic. Codegen unwraps to inner expression. 100% parity with production `ensureMove` architecture.

~~**FunctionExpr — DONE (Gap 16).**~~ Lambda lifting (Phase 3) now lifts ALL FunctionExpr and ArrowFunction — both capturing and non-capturing. Non-capturing: lifted to module-level FunctionDecl, replaced with Identifier. Capturing: env struct + closure pair (unchanged). Codegen never sees FunctionExpr/ArrowFunction nodes. 100% parity with production `lambdalifting` architecture.

**SpreadExpr — CORRECT for literal spread, but openArray is a separate feature.** Phase 3 `spreadExpand` inlines literal spreads (tuple field expansion, fixed array subscripts). Dynamic array spread emits inner expression. Production compilers don't have JS-style `[...a, ...b]` — they have `openArray` (ptr, len) calling convention, which is fundamentally different and far more impactful. See Gap 17.

---

## Optimization

### 10. Inline Arithmetic Magic

**Gap**: If builtinLower rewrites `a + b` (number) to `ms_add(a, b)`, that's a function call. C compiler might inline it, might not.

**Why production compilers have it**: Production compilers have 70+ "magic" ops that emit inline C. `mAddI` → `(a + b)`, `mEqStr` → `strcmp(a,b)==0`, `mLengthSeq` → `a->len`. No function call overhead. The C compiler's optimizer does better when operations are already inline.

**Why we don't**: Our builtinLower is an AST→AST transform — it can only rewrite to other AST nodes (function calls). Emitting raw C operators requires codegen awareness.

**How to close**:
Hybrid approach: builtinLower handles high-level rewrites (method→function). Codegen's `genBinaryExpr` checks operand types — for numeric types, emit inline `(a + b)`. For string types, emit `ms_concat(a, b)`. ~30 lines in expressions.ms. Keep builtinLower for everything else.

---

### 11. Sequence Construction Optimization

**Gap**: `[1, 2, 3]` emits `{ 1, 2, 3 }` (C initializer). No runtime array with length/capacity.

**Why production compilers have it**: Real arrays need metadata (length, capacity, refcount). Production compilers emit `newSeqPayload(3, sizeof(int))` then `data[0]=1; data[1]=2; data[2]=3;`. Supports dynamic growth, bounds checking, GC integration.

**Why we don't**: Our array literal emits C aggregate initializers — works for stack arrays but not for heap-allocated runtime arrays with RC.

**How to close**:
In `genArrayLiteral`, emit `ms_array_new(count)` + element assignments. Needs runtime array type (`msArray { data, len, cap, rc }`). ~40 lines codegen + ~50 lines runtime.

---

### 12. NRVO (Named Return Value Optimization)

**Gap**: Large struct returns copy via value. No detection of "function builds struct in local, returns it" pattern.

**Why production compilers have it**: Returning a large struct by value means: build in callee stack, copy to caller stack. NRVO detects when a named local IS the return value and constructs directly in caller's memory. Eliminates one full struct copy.

**Why we don't**: Requires caller to pass destination pointer as hidden parameter, callee to construct directly into it. Our codegen has no hidden parameter mechanism.

**How to close**:
1. Detect functions returning struct where last statement is `return localVar`
2. Add hidden `result` parameter (pointer to caller's destination)
3. Callee writes directly to `*result` instead of local
~100 lines in declarations.ms + expressions.ms. Low priority — C compiler's own NRVO often handles this.

---

## Deferred

### 13. Multi-Module C Generation

**Gap**: `generateC()` produces one string for one module. No multi-file C output, no header generation, no linking.

**Why production compilers have it**: Real programs have hundreds of modules. Production compilers emit one `.c` + one `.h` per module, compile in parallel, link together. Supports incremental compilation (rebuild only changed modules).

**Why we don't**: Single-module C output was the simplest starting point. Multi-module infrastructure exists (module/graph.ms) but codegen doesn't use it.

**How to close**:
1. `generateC` per module → `.c` file with implementations + `.h` with declarations
2. Module init ordering based on import graph
3. Link step: compile all `.c` files, link together
~200 lines. Depends on multi-module checker being solid first.

---

### 14. Write Barriers (GC Integration)

**Gap**: No `asgnRef`/`unsureAsgnRef` for heap reference assignments. Raw pointer assignment without GC notification.

**Why production compilers have it**: Generational/concurrent GC needs write barriers — when an old-gen object points to a new-gen object, the GC must track it. Without barriers, the GC misses roots and collects live objects. Production compilers emit `asgnRef(&dest, src)` for every ref assignment.

**Why we don't**: Our memory model is deterministic RC (Phase 4 analyzer). RC doesn't need write barriers — incref/decref handle lifetime. Barriers only matter for tracing GC.

**How to close**:
Not needed unless we add a tracing GC. Our DRC model is complete without barriers. Mark as intentionally omitted, not a gap.

---

### 15. ~~Move Marker Must Survive to DRC~~

**Gap**: `moveExprLower.ms` strips `move x` → `x` in Phase 3, before the DRC analyzer (Phase 4) ever sees it. The move marker's semantic intent is lost.

**Why production compilers keep it**: `move(x)` is not just syntax sugar — it's a **directive to the DRC**. Production compilers process `move()` inside `injectdestructors` where it: (1) strips the `mEnsureMove` wrapper, (2) sets `isEnsureMove` flag, (3) if `isLastRead(x)`: emits `=sink(dest, x) + wasMoved(x)`, (4) if NOT last read: emits `=copy` **with an error** because the programmer explicitly requested a move that can't happen. The marker forces sink semantics and enables diagnostics.

**Why we don't**: We designed `moveExprLower` as a simple Phase 3 strip pass, treating `move` as syntactic. DRC independently decides sink vs copy via `isLastRead`, unaware the programmer intended a move.

**Status: DONE.** Implemented in `inject.ms` — 5 tiers of production-compiler parity:

1. **Core identifier move** (Tier 1): `emitMoveSourceWasMoved()` central helper. 7 code paths patched: `processVarDecl`, `processAssignment`, `processCallArgs`, `emitSaveAssignDestroy`, `markReturnedVarsMoved`, `emitLiteralFieldCopies`, `emitArrayElementCopies`.
2. **Field/array source** (Tier 2): `classifyMemberFieldRc()`, `classifyArrayElementRc()` — emit `wasMoved` on `move obj.field` and `move arr[i]`.
3. **Aliased move protection** (Tier 3): `x = move x.field` → capture pattern (tmp = field, zero field, destroy old, assign tmp). Prevents use-after-free.
4. **errFailedMove diagnostic** (Tier 4): When `move x` used but x is not last-read, emits compile error.
5. **Literal construction moves** (Tier 6): `{ f: move x }` and `[move x]` emit `wasMoved` + `recordMove` instead of incref.

Tier 5 (first-write sink optimization) deferred — requires DrcContext struct change blocked by DRC gotcha #18.

**Additional parity (post-Gap-15)**:
- ~~**Type fix**: `checkExprPass.ms` MoveExpr now returns inner expression type (was `unknownType()`).~~
- ~~**Operand validation**: Rejects non-identifier/member/array/call operands at type-check time.~~
- ~~**sinkFn optimization**: `makeSinkCall()` wired in 3 `processAssignment` paths — `sink(dest,src)` replaces `destroy(old)+assign` when `sinkFn !== ""`.~~
- ~~**Inline sink in hook bodies**: `destructorLifting.ms` `=sink` bodies emit inline `destroy(field) + assign` instead of runtime `_sink()` calls. All type families updated (string, array, closure, map, set, named). `refOp` already optimal.~~
- ~~`moveExprLower.ms` removed from Phase 3 native pipeline — MoveExpr survives to Phase 4 and Phase 5.~~
- **100% parity** with reference architecture on move semantics across all pipeline phases.

---

### 16. Lambda Lifting Must Handle All FunctionExpr

**Gap**: Non-capturing `FunctionExpr` nodes survive to codegen, where they're lifted to module-level with a placeholder body (`/* func expr body */`). This is a workaround for circular imports between expressions.ms and statements.ms — codegen can't call `genStmts` from `genExpr`.

**Why production compilers solve this in transforms**: Lambda lifting runs BEFORE codegen as an AST-to-AST transform. It recursively processes ALL inner procs (capturing and non-capturing), stores their transformed bodies on the symbol, and replaces function expressions with either: (a) closure struct `{funcPtr, envPtr}` if captures exist, or (b) plain function pointer reference if no captures. By the time codegen runs, there are no inline function definitions — only references to already-processed top-level functions.

**Why we don't**: Our `lambdaLifting.ms` (Phase 3) focuses on closures with captures. Non-capturing function expressions pass through unchanged, leaving codegen to handle them with the placeholder workaround.

**How to close**:
1. In `lambdaLifting.ms`, detect ALL `FunctionExpr` nodes (not just capturing ones)
2. For non-capturing: lift to a module-level `FunctionDecl`, replace the expression with an `Identifier` referencing the lifted function
3. For capturing: already handled — create env struct + lifted function + closure pair
4. Remove `genFunctionExpr` from codegen (should never see `FunctionExpr` after transforms)
~80 lines in lambdaLifting.ms. Codegen safety net: if FunctionExpr somehow survives, emit `/* unlifted func expr */` warning.

---

### 17. openArray Calling Convention (ptr, len)

**Gap**: No zero-copy array/slice passing. Every function receiving variable-length data gets a heap-allocated array with refcount overhead. No way to borrow existing array data without copying.

**Why production compilers have it**: The `openArray(ptr, len)` convention is perhaps the single most impactful C-backend optimization. It enables: (1) zero-copy array passing — `f(stackArr, 5)` with no allocation, (2) zero-copy slicing — `f(arr + 2, 4)` borrows a window, (3) efficient varargs — `f("a", "b", "c")` collects into stack array, passes `(ptr, 3)`, (4) no lifecycle overhead — views don't trigger refcount ops. Production compilers use two representations: **parameter mode** (two C params: `T* data, int dataLen_0`) and **value mode** (struct: `{ T* Field0; int Field1; }`). At call sites, `openArrayLoc` extracts (ptr, len) from arrays, sequences, strings, slices — all zero-copy.

**Why we don't**: MetaScript has JS-style `...spread` (AST-level expansion) but no borrowing/view abstraction. Every array parameter is an owned `T[]` with full lifecycle management. No concept of "borrow this data without owning it."

**How to close**:
1. **Type system**: Add `openArray<T>` or `Slice<T>` parameter type in checker — marks "borrows (ptr, len), does not own"
2. **Calling convention**: For `openArray<T>` params, emit two C params: `T* data, int dataLen_0`
3. **Call site rewriting**: In codegen or a transform, extract (ptr, len) from the argument:
   - `T[N]` (fixed array) → `(arr, N)` — compile-time constant length
   - `T[]` (dynamic array) → `(arr.data, arr.len)` — extract fields
   - `string` → `(str.data, str.len)` — zero-copy char access
   - `arr[start..end]` (slice) → `(arr.data + start, end - start + 1)` — zero-copy window
4. **Varargs**: Semantic phase collects `f(a, b, c)` into stack array literal, passes as (ptr, len)
~200 lines across checker + codegen. Requires runtime array struct to have accessible `data`/`len` fields.

---

**Gap #9 status**: ~~All 5 expression kinds done.~~ UpdateExpr correct, NewExpr acceptable (debt), SpreadExpr correct, ~~MoveExpr → Gap 15 (DONE)~~, ~~FunctionExpr → Gap 16 (DONE)~~. openArray → Gap 17 (separate feature).

**Total to close remaining gaps**: ~1000-1200 lines (gaps 3, 5, 6, 7, 8, 10, 11, 12, 13, 17)
**Current codegen**: ~3200 lines across 9 files (+ ~860 lines pre-codegen transforms)
**Target**: ~4500 lines for production parity

---

## JS Backend

### 18. Mutable String Design (Cross-Backend)

**Gap**: Strings are immutable. No `s[i] = ch` or `.add()`. Limits systems programming use cases that need in-place string building, character replacement, or buffer accumulation.

**Why Nim does it**: Nim has 1 mutable string type — `var s = "hello"; s[0] = 'H'; s.add(" world")` all work. This is why Nim's JS backend must use char code arrays instead of native JS strings (JS strings are immutable, can't support `s[0] = 'x'`). The char array approach is correct but produces ugly, slow JS output.

**Our design**: Mutable strings as a **TypeScript superset**. All TS string code works unchanged — TypeScript never mutates strings, so allowing mutation breaks nothing. It's purely additive.

```
// TypeScript-compatible (unchanged behavior)
const s = "hello";            // const → no mutation, no reassignment (same as TS)
let t = s.slice(1);           // returns new string (same as TS)
let u = s + " world";        // concat returns new string (same as TS)

// MetaScript extension (new capability)
let buf = "hello";
buf[0] = "H";                // char assignment — TS rejects this, MS allows it
buf.add(" world");           // in-place append
// buf is now "Hello world"
```

**Key rules**:
- `const` strings: immutable — `const s = "x"; s[0] = "y"` is a compile error (same as TS)
- `let` strings: reassignable (same as TS) AND mutable (MS extension)
- `.slice()`, `.replace()`, `+` concat: return new strings (same as TS)
- `s[i] = ch`, `.add()`: new mutation ops, no existing TS code uses them
- `s += "more"`: already works as reassignment in TS; C backend can optimize to in-place append

**Per-backend implementation**:
- **C**: `msString {data, len, cap, rc}` — growable COW buffer (like Nim ARC). `s[i] = ch` mutates in-place. When `rc > 1` (shared), COW copies before mutating. Assignment `b = a` increfs the shared buffer.
- **JS**: Native `String` preserved — no char arrays, no Nim-style ugliness. Mutation compiles to reassignment: `s[i] = ch` → `s = s.slice(0,i) + ch + s.slice(i+1)`. `s.add(x)` → `s += x`. Same observable behavior, O(n) instead of O(1).

**Encoding**: UTF-8 in C, UTF-16 in JS. Identical behavior for ASCII range (0-127). Non-ASCII diverges — `"😀".length` is 4 bytes in C, 2 code units in JS. Accept this pragmatically: most systems strings are ASCII (paths, identifiers, protocols). Future `Rune` iterator type for explicit codepoint-level Unicode work.

**How to close** (~280 lines):
1. **Checker** (~30 lines): Allow index-assignment on string type for `let` bindings. Reject for `const`.
2. **JS transform** (~50 lines): `stringMutationLower` rewrites `s[i] = ch` and `s.add(x)` to slice+concat reassignment.
3. **C runtime** (~150 lines): `ms_string_set_char()`, `ms_string_add()`, `ms_string_cow()`. COW copy when refcount > 1.
4. **Tests** (~50 lines): const mutation error, let mutation works, COW isolation, cross-backend ASCII parity.

---

### 19. String/Array Runtime Architecture

**Relocated to [LANG-RUNTIME.md](LANG-RUNTIME.md)** — covers the full runtime architecture including ORC (pure C), string/array runtime (MetaScript .ms), operation dispatch map (codegen vs stdlib), mutable string cross-backend design, and per-backend representation choices.

---

### 20. JS Performance & Bundle Optimization

**Gap**: JS output is functional but not optimized for production deployment. No minification awareness, no tree-shaking validation, no bundle size tracking.

**Why this matters**: Nim's env-object closures were benchmarked against native closures on older engines. Our native-everything approach is correct for modern engines but hasn't been validated. Production JS transpilers (TypeScript, Babel, SWC) all consider output size and runtime performance.

**Specific items**:
- **Enum IIFE overhead**: Bidirectional mapping (`Color[Color["Red"] = 0] = "Red"`) doubles enum size vs plain integers. Useful for debugging but costly in production.
- **Result object allocation**: Every `Result.ok(x)` creates `{ ok: true, value: x }` — hot paths may benefit from V8 hidden class optimization or inlining.
- **Dead export elimination**: ES6 `export` enables tree-shaking by bundlers, but our codegen may emit unused helpers.
- **Source maps**: No source map generation — debugging JS output requires manual correlation to .ms source.
- **Bundle size baseline**: No measurement of output size vs input size ratio.

**How to close**:
Phase 1: Add `--release` flag for JS that emits plain integer enums, skips debug helpers. ~50 lines.
Phase 2: Source map generation (line mapping from .ms to .js). ~200 lines.
Phase 3: Benchmark suite comparing MetaScript JS output perf vs hand-written JS. ~100 lines.

---

### 21. Default Parameter Limitations

**Status: PARTIAL — core works, two edge cases remain.**

Default parameters (`function f(x: number = 5)`) are implemented end-to-end: parser captures default text in `DefaultParamStore` (context.ms), `minArity` encoded in `typeFlags` bits 8-15 (types.ms), flexible arity scoring in `scoreCandidatePriority` (compat.ms), call-site filling via `fillDefaultArgsForNode` (checkExprPass.ms). Simple literal defaults (numbers, strings, booleans, null, identifiers) work for same-module calls.

**Remaining limitations**:

1. **Cross-module defaults**: `DefaultParamStore` is a process-global side-channel keyed by function name. Defaults are only available within the module that parsed them. Calling `f(1)` from another module when `f(x: number, y: number = 5)` is defined elsewhere fails — the caller doesn't have the default text. Production compilers store defaults on the parameter Symbol (`PSym.ast` field) so they travel cross-module for free via symbol sharing.

2. **Complex default expressions**: `defaultTextToNode()` only handles simple literals (`5`, `"hello"`, `true`, `false`, `null`, identifiers). Expressions like `f(x = a + b)`, `f(x = someFunc())`, or `f(x = [1, 2])` are stored as text but fail to reconstruct into AST nodes. Fix: lex the text and run the expression parser instead of pattern-matching literals.

3. **`const r = f(1)` DRC interaction**: Assigning default-filled call results to a variable (`const r = f(1);`) triggers DRC heap-use-after-free. Statement-form calls (`f(1);`) work fine. Root cause: DRC cleanup of the Result interacts with the newly-inserted default argument nodes.

**How to close**:
- Issue 1: Module-qualify store keys (`modulePath + ":" + fnName`), or migrate to storing defaults on Symbol (matches production architecture). ~50 lines.
- Issue 2: Replace literal matching in `defaultTextToNode` with `lex(text) → createState → parseExpression`. ~30 lines, isolated change.
- Issue 3: Investigate DRC interaction with inserted nodes in assignment context. ~20 lines.

---

## Design Note: String/Array Operator Codegen (Why Not `std/core.ms`)

MetaScript has operator overloading and subscript overloading (reference compiler supports both). In theory, all string/array operations could be declared in `std/core.ms` with `@runtime` decorators, making codegen type-unaware. However, 9 operations are intentionally handled in codegen (`expressions.ms`) for the same reason Nim uses `{.magic.}` in `ccgexprs.nim` instead of normal overloaded procs:

### Operations handled in codegen

| Pattern | C Emission | Why codegen |
|---------|-----------|-------------|
| `s.length` | `s.len` | Direct struct field access — zero-cost, no function call |
| `arr.length` | `arr.len` | Same |
| `s == t` / `s === t` | `ms_string_equals(s, t)` | Empty string optimization: `s == ""` → `(s.len == 0)` (future) |
| `s != t` / `s !== t` | `(!ms_string_equals(s, t))` | Same |
| `s < t` / `s > t` / `<=` / `>=` | `(ms_string_compare(s, t) op 0)` | Comparison family shares one runtime call |
| `s + t` | `ms_string_concat(s, t)` | **Concat chain fusion** (Gap #8): `s + t + u` → single allocation |
| `s[i]` read | `ms_string_char_at(s, i)` | Bounds checking injection point (Gap #6) |
| `s[i] = ch` | `(ms_prepare_str_mutation(&s), ms_string_set_char(&s, i, ch))` | ~~COW mutation guard~~ DONE |
| `arr[i]` | `arr.p->data[i]` | Direct data access — no function call overhead |

### Why Nim uses magic for the same operations

Nim has full operator overloading. `len`, `==`, `<`, `&`, `[]`, `[]=` are all declared as `proc` in `system.nim` with `{.magic.}` pragmas. The magic tag tells codegen to emit specialized C instead of a function call. Reasons:

1. **Concat chain fusion**: `s & t & u & v` — magic walks the AST, collects all segments, emits ONE `rawNewString(total_len)` + N `appendString()` calls. A normal `proc &(a, b: string): string` would allocate N-1 intermediate strings.

2. **Compile-time literal folding**: Magic sees `"hello"` in the AST and knows its length at compile time. Pre-allocates exact size. A normal proc receives a runtime value.

3. **Empty string fast path**: `s == ""` → `(s.len == 0)` — no function call. Magic inspects the literal AST node.

4. **Aliasing safety**: `s = "x" & s & "y"` — magic allocates new buffer first, reads old `s`, then assigns. Nested proc calls risk use-after-free.

5. **Direct field access**: `s.len` as a struct field read is zero-cost. Even `static inline` functions have call-site overhead the optimizer may not eliminate in debug builds.

### What stays in `std/core.ms`

All **method calls** (`s.trim()`, `s.includes()`, `arr.push()`, etc.) go through the `@runtime` pipeline — no codegen awareness needed. Only **operators**, **properties**, and **subscripts** require codegen handling because their optimizations depend on AST structure visibility.

### Future: operator overloading in self-hosted compiler

MetaScript the language supports operator/subscript overloading (reference compiler implements it). Once the self-hosted compiler implements these features, the _simple_ cases (equality, comparison) could move to `std/core.ms`. But concat chain fusion and bounds checking will always need codegen involvement — the optimization is fundamentally above the procedure-call abstraction level.

---

## Optimization TODO: Runtime Dead Code Elimination

**Current**: `runtime/core/string.c` + `runtime/core/array.c` are compiled and linked in full — all 60+ functions present in every binary regardless of usage.

**Nim's approach**: Runtime procs are Nim source (strs_v2.nim, seqs_v2.nim) that flow through the same compilation pipeline as user code. Dead code elimination at codegen level — only reachable procs get C code emitted. Zero waste.

**Our gap**: Our runtime is pre-written C, bypasses the MetaScript pipeline entirely.

**Options (easiest → hardest)**:

| Approach | Effort | Effect |
|----------|--------|--------|
| `-Wl,-dead_strip` (macOS) / `-ffunction-sections -Wl,--gc-sections` (Linux) in cc.ms | 1 line | Linker strips unreachable functions from binary |
| Split runtime into per-function headers with `static inline` | Medium | Compiler DCE at compile time |
| Write runtime in MetaScript with `@runtime` + codegen-on-demand | Large | True Nim parity — only referenced functions exist in C output |

Option 1 is sufficient for now. Option 3 is the long-term architectural goal.

---

## Design Note: `nodeType` Field

Gap #2 required every expression node to carry its resolved type (like Nim's `n.typ: PType`). The field is `nodeType: Type` on the Node interface, set by `checkExpr()` during Phase 2. Types are owned by CheckerContext and outlive Nodes — safe borrowed reference. Initialized to `null as unknown as Type` in `createNode()`.
