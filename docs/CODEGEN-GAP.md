# C Codegen Gap Analysis

Gaps between our C codegen (~2.8K lines, 8 files) and a production-grade C backend (~10K lines).
Each item: what's missing, why production compilers have it, why we don't yet, how to close.

---

## Blocking

### 1. Generic Monomorphization

**Gap**: `Array<number>` vs `Array<string>` emit identical `void*` code. No per-type specialization.

**Why production compilers have it**: Generics are everywhere — containers, Result, Option, itertools. Without monomorphization, every generic becomes `void*` with runtime casts, losing type safety and performance. Production compilers maintain an instantiation registry mapping `(func, [typeArgs])` to specialized AST copies, then emit distinct C code per combination.

**Why we don't**: Type-level inference works (`substituteType`, `inferGenericReturn` in checkExprPass.ms:213), but no AST duplication infrastructure. The checker resolves return types correctly — it just doesn't clone function bodies.

**How to close**:
1. Add `instantiationRegistry` to CheckerContext — maps `"funcName<int,string>"` to cloned FunctionDecl
2. Add AST clone utility (deep-copy a Node subtree, substituting GenericParam types)
3. Add monomorphization transform between checker and existing transforms
4. Codegen mangles names per specialization: `id_number`, `id_string`
~400 lines. Blocked on checker work, not codegen.

---

### 2. Pointer Accessor (-> vs .)

**Gap**: `genMemberExpr` always emits `.` (expressions.ms:129). Classes are `ClassName*` (heap-allocated pointers) — need `->`.

**Why production compilers have it**: Type-directed emission is fundamental. The accessor depends on whether the object is a value type (`.`) or pointer type (`->`). Production compilers check `typ.kind` at every member access site. Wrong accessor = C compilation failure.

**Why we don't**: Codegen doesn't read `node.nodeType` yet. The type info IS on the AST (checker annotates it), we just skip it.

**How to close**:
Check `node.nodeType` in `genMemberExpr`. If object type is class/ref/ptr → emit `->`, else `.`. Already have `isPointerType()` in types.ms:86. ~10 lines.

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

### 4. std/core.ms Auto-Import

**Gap**: No standard library bootstrap. Types like `console`, `Result`, `Promise`, `Array` methods have no signatures available to the checker or codegen.

**Why production compilers have it**: Every production compiler compiles a "system" module first, injecting its exports into every user module's scope. This is how `print()`, `len()`, `assert()` work without explicit imports. Without it, there's nothing to call.

**Why we don't**: Multi-module infrastructure exists (module/, loader.ms, graph.ms) but no `std/core.ms` file with `@runtime`/`@builtin` annotated declarations.

**How to close**:
1. Create `std/core.ms` with annotated declarations for ~30 core functions
2. In compileSource/compileProject, compile core.ms first
3. Inject core.ms exports into every module's initial scope
~200 lines for core.ms, ~30 lines for injection wiring.

---

## Functional

### 5. RTTI / Type Info Tables

**Gap**: No runtime type information. Can't dispatch exceptions by type, can't use `is` operator at runtime.

**Why production compilers have it**: Exception dispatch needs RTTI — `catch (e: SpecificError)` must check `e`'s actual type against `SpecificError` at runtime. Also needed for: `isinstance`/`is` checks, reflection, debugger type display. Production compilers emit `TNimType` structs with name, size, field info, parent chain.

**Why we don't**: Our try/catch uses setjmp/longjmp (statements.ms:175-206) but catches ALL exceptions — no type filtering. We haven't needed `is` checks yet because the type system is static.

**How to close**:
1. Add `TypeInfo` struct emission in types.ms (name + id + parent pointer)
2. Emit type info table in CSection.Types for each class/interface
3. Exception dispatch: compare `curr_exception->typeInfo->id` against target
~150 lines in types.ms + 50 lines in statements.ms.

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

### 9. Missing Expression Kinds

**Gap**: UpdateExpr (`i++`), NewExpr (`new Foo()`), MoveExpr (`move x`), SpreadExpr (`...arr`) hit `/* unsupported expr */0` fallback (expressions.ms:83).

**Why production compilers have it**: These are common language features. `i++` appears in every loop. `new` is how classes are constructed. `move` is the ownership transfer primitive.

**Why we don't**: Most should be lowered by Phase 3 transforms before reaching codegen. `i++` → `i = i + 1`, `new Foo(x)` → `Foo_new(x)`, `move x` → assignment + null source. They're gaps in Phase 3, not codegen.

**How to close**:
- `UpdateExpr`: add to expressions.ms — `i++` → `i++`, `++i` → `++i`. Direct C mapping. ~15 lines.
- `NewExpr`: Phase 3 transform to `ClassName_new(args)` call. ~40 lines in transforms.
- `MoveExpr`: Phase 3 transform to `dest = src; ms_was_moved(&src)`. ~30 lines.
- `SpreadExpr`: Phase 3 transform to loop expansion. ~60 lines.

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

## Summary Table

| # | Gap | Severity | Effort | Blocked? |
|---|-----|----------|--------|----------|
| 1 | Generic monomorphization | Blocking | ~400 lines | Yes (checker) |
| 2 | Pointer accessor (-> vs .) | Blocking | ~10 lines | No |
| 3 | @builtin expansion | Blocking | ~200 lines | No |
| 4 | std/core.ms auto-import | Blocking | ~230 lines | No |
| 5 | RTTI / type info | Functional | ~200 lines | No |
| 6 | Bounds checking | Functional | ~20-100 lines | No |
| 7 | Overflow checking | Functional | ~80 lines | No |
| 8 | String concat optimization | Functional | ~80 lines | No |
| 9 | Missing expression kinds | Functional | ~145 lines | Partial (Phase 3) |
| 10 | Inline arithmetic magic | Optimization | ~30 lines | No |
| 11 | Sequence construction | Optimization | ~90 lines | No |
| 12 | NRVO | Optimization | ~100 lines | No |
| 13 | Multi-module C output | Deferred | ~200 lines | Needs multi-module checker |
| 14 | Write barriers | N/A | 0 lines | Intentionally omitted (DRC) |

**Total to close all gaps**: ~1500-1800 lines (excluding generic monomorphization checker work)
**Current codegen**: ~2800 lines across 8 files
**Target**: ~4500 lines for production parity
