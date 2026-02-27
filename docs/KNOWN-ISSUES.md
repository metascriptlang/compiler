# Known Issues — Reference Compiler Workarounds

Workarounds for bugs in the reference compiler (Zig-based `msc`). Each entry: problem, context, why, how to fix.

---

## 1. `let x; x = try f()` — use-after-free

**Problem:** Declaring a variable with `let` then assigning from `try` crashes at runtime.
**Context:** `let result; result = try parseExpr(state);` — the intermediate Result is destroyed before the value is extracted.
**Why:** The analyzer inserts a destroy call for the Result between the `try` unwrap and the assignment to the `let` variable.
**Fix:** Always use `const x = try f();` in a single declaration. Never separate declaration from try-assignment.

---

## 2. Fresh interface as function argument — double-free

**Problem:** Passing a freshly constructed interface directly as a function argument causes double-free.
**Context:** `defineOrError(ctx, makeSymbol("x", kind, unknownType(), false), node);` — the temporary returned by `makeSymbol` is freed twice.
**Why:** The analyzer generates destroy calls for both the temporary at the call site AND inside the callee's parameter scope.
**Fix:** Store in a local `const` first: `const sym = makeSymbol(...); defineOrError(ctx, sym, node);`

---

## 3. `string[]` / `Node[]` are value types — mutation loss

**Problem:** Pushing to an array inside a function does not propagate to the caller.
**Context:** `function addItem(arr: string[], item: string) { arr.push(item); }` — caller's array unchanged after call.
**Why:** Arrays are value types in MetaScript. Function parameters receive a copy, so mutations are local to the callee.
**Fix:** Wrap arrays in an interface: `interface Items { items: string[]; }` — interfaces are pointer types, so mutations propagate. See `src/analyzer/scope.ms` lines 26-40.

---

## 4. `try` in match arms — unsupported codegen

**Problem:** Using `try` expressions inside match arm blocks emits `/* unsupported: try_expr */` in generated C.
**Context:** `match (kind) { A => { const x = try f(); ... }, _ => {} }` — the try is silently dropped.
**Why:** The match-to-switch lowering does not handle try expression desugaring inside arm blocks.
**Fix:** Use if-else chains when any branch needs `try`. Or hoist the try above the match.

---

## 5. `break`/`continue` in match arms — targets wrong loop

**Problem:** `break` and `continue` inside match arms target the generated switch statement, not the enclosing loop.
**Context:** `for (const x of items) { match (x) { A => { continue; }, _ => {} } }` — the continue skips the switch case, not the for loop.
**Why:** Match expressions lower to switch statements. `break`/`continue` bind to the nearest switch, not the outer loop.
**Fix:** Set a flag variable inside the match arm, then check it after the match to break/continue the outer loop.

---

## 6. Standalone `try` in while loop — scope bug

**Problem:** `try f();` as a standalone statement inside a while loop makes all outer variables undeclared.
**Context:** `while (hasMore) { try advance(state); }` — variables declared before the loop become invisible.
**Why:** The analyzer's scope tracking has a bug with standalone try expressions (not assigned to a variable) inside loop bodies.
**Fix:** Wrap in assignment (`const _ = try f();`) or call a non-Result wrapper function (e.g., `advance()` that handles the Result internally).

---

## 7. No `indexOf` / `includes` on strings

**Problem:** String methods `indexOf` and `includes` are not available in the standard library.
**Context:** `if (str.includes("x"))` or `str.indexOf("y")` — compile error, method not found.
**Why:** The reference compiler's string type only exposes `length`, `slice`, `charAt`, and a few others. These methods were never implemented.
**Fix:** Use utilities from `src/utils/string.ms`: `findChar(str, ch)` returns index or -1, manual `slice` + comparison for substring search.

---

## 8. `type` is a reserved keyword

**Problem:** Using `type` as a variable or parameter name causes a parse error.
**Context:** `const type = getNodeType(node);` — fails because `type` is reserved for type alias declarations.
**Why:** The lexer classifies `type` as a keyword token unconditionally, even in expression context.
**Fix:** Use alternative names: `nodeType`, `tokenType`, `symType`, `typeKind`, etc.

---

## 9. Circular imports silently drop

**Problem:** When two files import each other, one import is silently ignored — no error, no warning.
**Context:** `a.ms` imports `b.ms`, `b.ms` imports `a.ms` — one direction works, the other gets empty bindings.
**Why:** The module loader detects the cycle and skips the second import to avoid infinite recursion, but doesn't report it.
**Fix:** Keep mutually recursive functions in the same file. For cross-file dependencies, use the callback injection pattern (see `src/parser/statements/callbacks.ms`).

---

## 10. C-style `for` in match arms — codegen unreachable

**Problem:** `for (let i = 0; i < n; i += 1) { ... }` inside a match arm block hits a codegen assertion.
**Context:** Match arms lower to switch cases. The C-style for loop's initializer/update aren't normalized inside switch blocks.
**Why:** The transform pipeline normalizes for-loops but runs BEFORE match lowering. The lowered switch blocks contain un-normalized for-loops.
**Fix:** Use `while` loops or `for..of` inside match arms. Both work correctly in lowered switch blocks.

---

## 11. DRC lifecycle mangling — cross-module complex fields

**Problem:** Storing `Node`, `Symbol`, or other complex types as fields on interfaces defined outside their home module generates lifecycle hooks with wrong module paths, causing crashes.
**Context:** `interface Module { ast: Node; }` in `module/graph.ms` — the generated `Node_destroy` call uses `graph.ms`'s module path instead of `ast/node.ms`.
**Why:** The DRC analyzer resolves lifecycle function names using the defining module's path, but when a type appears as a field in another module, it picks up the wrong path.
**Fix:** Keep module-level interfaces lightweight (primitives, `string`, `string[]` only). Store complex types in parallel arrays managed externally. See `src/module/graph.ms` lines 8-11.

---

## 12. `emptyType()` sets typeReturn/typeExtra to NULL

**Problem:** Function types created via `emptyType()` have NULL typeReturn, causing null pointer dereference when accessed.
**Context:** `const t = emptyType(); t.kind = TypeKind.Function;` — accessing `t.typeReturn.kind` crashes because typeReturn is NULL.
**Why:** The flat Type interface initializes all fields to zero/null/empty. typeReturn and typeExtra are set to `null as unknown as Type`.
**Fix:** Always set `typeReturn = unknownType()` explicitly after creating a Function type. Use the `createFunction()` constructor which does this automatically.

---

## 13. `std/fs` existsSync pulls broken module

**Problem:** Importing from `std/fs` triggers a codegen bug in the existsSync implementation.
**Context:** `import { existsSync } from "std/fs";` — compiles but crashes at runtime due to broken generated code.
**Why:** The std/fs module has a codegen issue in its file existence check implementation that produces invalid C.
**Fix:** Import only from `std/fs/path` which provides `dirname` and `join` safely. For file existence, use alternative approaches.

---

## 14. String return from functions in loops — refcount over-decrement

**Problem:** Calling a function that returns a string inside a loop causes the returned string's refcount to be decremented too many times.
**Context:** `while (i < n) { const name = getName(items[i]); ... }` — after several iterations, the string is freed prematurely.
**Why:** The DRC analyzer generates a destroy call for the previous iteration's return value, but the refcount bookkeeping doesn't account for the loop re-entry correctly.
**Fix:** Pre-compute all string results into an interface-wrapped array before the loop: `interface Names { items: string[]; }`. Then access by index inside the loop. See `src/transform/analysis/dce.ms` lines 131-155.

---

## 15. Loop-var vs param codegen — value copy vs pointer

**Problem:** `const d = loopVar.data as XData` inside `for..of` generates a VALUE COPY, while the same code with a function parameter generates a POINTER.
**Context:** Mutating `d.field` inside a for..of loop has no effect because `d` is a copy. The same code in a function taking `node` as param works because `d` is a pointer.
**Why:** The codegen emits `const struct XData d = ...` for loop variables (stack copy) but `XData* d = &...` for function parameters (pointer to union member).
**Fix:** Extract mutation logic into a separate function that takes the node as a parameter. The function parameter path generates correct pointer access.

---

## 16. Local Node var in return — use-after-free

**Problem:** Storing a node in a local variable then accessing its data fields in a return statement causes use-after-free.
**Context:** `const arg = cd.arguments[0]; return (arg.data as X).name;` — `arg` is destroyed before `name` is extracted from it.
**Why:** The DRC inserts destroy for `arg` at scope exit, which runs before the return value is fully evaluated.
**Fix:** Access inline without intermediate variable: `return (cd.arguments[0].data as X).name;`

---

## 17. Interface name collision in C namespace

**Problem:** Two interfaces with the same name in different files cause C compilation errors or wrong function binding.
**Context:** `ScopeStack` defined in both `analyzer/scope.ms` and `lambdaLifting.ms` — the C backend generates duplicate struct definitions.
**Why:** All MetaScript types share a single flat C namespace. There is no module-level name mangling for type definitions.
**Fix:** Use prefixed names that are unique across the project: `DrcScopeStack` vs `ScopeStack`. Check for existing names before defining new interfaces.

---

## 18. NodeData union size change breaks ms_clone

**Problem:** Adding fields to the NodeData union can cause `for..of` over `Node[]` to emit broken `ms_clone` calls.
**Context:** After extending NodeData with a new variant, existing `for (const node of nodes)` loops crash with memory corruption.
**Why:** The `ms_clone` function is generated based on union size. When the union grows, stale clone implementations may copy the wrong number of bytes.
**Fix:** Convert affected `for..of` loops to `while` loops with index access: `while (i < nodes.length) { const node = nodes[i]; ... }`. Rebuild with `rm -rf .zig-cache`.

---

## 19. Closure function name collision across files

**Problem:** Two files defining local functions with the same name can cause the closure codegen to bind to the wrong function.
**Context:** `expandStmt()` in both `file1.ms` and `file2.ms` — lambda lifting may capture the wrong function pointer.
**Why:** Lambda lifting generates closure environment structs using function names. Identical names in different files can collide in the C namespace.
**Fix:** Always use globally unique function names: `expandArrayMethodStmt` instead of `expandStmt`. Prefix with the module's purpose.

---

## 20. CallExprData / union members as function params — double-free

**Problem:** Passing a union member type (e.g., `CallExprData`) as a function parameter causes value-copy semantics at the call site but pointer access inside the callee.
**Context:** `function process(cd: CallExprData) { ... }` called with `process(node.data as CallExprData)` — the cast creates a copy that's freed twice.
**Why:** Union member access via `as` creates a temporary copy. The DRC generates destroy for both the temporary and the parameter.
**Fix:** Pass the parent `Node` instead and cast inside the function: `function process(node: Node) { const cd = node.data as CallExprData; ... }`. Or extract needed fields via helper functions.

---

## 21. Conditional string emit in while loop — scope mismatch

**Problem:** `if (cond) emit(gen, sep);` inside a while loop causes DRC to declare a discard variable inside the if-scope but emit cleanup outside it.
**Context:** Emitting a separator conditionally between items in a loop — the generated C has mismatched variable scopes.
**Why:** The DRC's discard variable for the string parameter is scoped to the if-block, but the cleanup call is emitted at the loop body level.
**Fix:** Restructure to avoid conditional string emission: emit the first item before the loop, then loop from index 1 with unconditional separator + item emission.

---

## 22. Cross-module Node/Node[] returns — lifecycle mismatch

**Problem:** A helper module that imports NodeData union member types and returns `Node` or `Node[]` to the caller causes ASan SEGV crashes.
**Context:** `decoratorHelpers.ms` imports `DecoratedDeclData`, returns `Node` via `getDecoratedInnerNode()` — caller in `collectPass.ms` crashes on the returned Node.
**Why:** Each compilation unit generates its own lifecycle hooks (ms_clone, ms_destroy) for the NodeData union based on which member types are visible. When a Node crosses module boundaries, the caller's hooks disagree with the callee's hooks on union layout.
**Fix:** Helper modules must return only primitives (string, number, enum, simple interfaces with primitive fields). Keep Node/Node[] access local to the file that uses it. See `src/checker/decoratorHelpers.ms` for the pattern.
