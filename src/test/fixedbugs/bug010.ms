// bug010 — Map<K, FunctionType> caller/stdlib mono name divergence
//
// Symptom:    Storing closures/lambdas in a Map (or any generic class with a
//             function-typed type arg) produced a chain of C-level errors:
//                 OrderedMapEntry__string_function (caller side, properly
//                                                    typed)
//                 OrderedMapEntry__string_Function (stdlib side, all void*)
//                 OrderedMapEntry__string_unknown  (linker error)
//                 assigning to '...string_function' from incompatible
//                 type '...string_unknown'
//             Map.set / Map.get / Map.has all undefined-symbol at link.
//             Hit by ion command-builder's handler dispatch (`Map<string,
//             Handler>` for event handlers).
//
// Root cause: The mono pipeline used TWO naming functions for the same
//             `TypeKind.Function`:
//               - `monoTypeKey(t)`         → "function" (lowercase) — used by
//                 C-name mangling in `mangleMonoName`.
//               - `monoConcreteTypeName(t)`→ "Function" (capital) — used by
//                 `substituteTypeStrings` to substitute generic param names
//                 in stdlib's class-body field-type annotation strings.
//             After substitution stdlib's body had `OrderedMapEntry<string,
//             Function>`. Re-resolving "Function" as a type symbol failed
//             (no `Function` alias in scope), the type fell back to
//             Unknown, and downstream emission produced two struct copies
//             with disagreeing layouts and mangled names. Caller's path
//             went through the Type-based mangler and produced
//             `_string_function`; stdlib's substituted-then-reresolved path
//             produced `_string_Function` / `_string_unknown`. Linker saw
//             multiple definitions of the same logical type with
//             incompatible field types and undefined symbols for the
//             instantiated methods.
//
// Fix:        `monoConcreteTypeName(Function)` now emits the function-type
//             literal — the same surface syntax the user types — instead
//             of the bare placeholder "Function". After substitution the
//             field type reads e.g. `OrderedMapEntry<string, (s: string)
//             => void>`, which roundtrips through `resolveAnnotation` back
//             to a `TypeKind.Function` Type identical to the caller's,
//             and downstream mangling lines up across both paths.

type Handler = (s: string) => void;

test "bug010: Map<string, Handler> stores and retrieves closures" {
	const m: Map<string, Handler> = new Map<string, Handler>();
	m.set("a", (s) => {});
	m.set("b", (s) => {});
	assert m.has("a");
	assert m.has("b");
	assert !m.has("c");
}

type IntFn = (x: int32) => int32;

test "bug010: Map<string, FunctionType> with custom return type" {
	const ops: Map<string, IntFn> = new Map<string, IntFn>();
	ops.set("double", (x) => (x * 2) as int32);
	ops.set("inc", (x) => (x + 1) as int32);
	assert ops.has("double");
	assert ops.has("inc");
	assert ops.size == 2;
}

// Round-trip: store, retrieve, INVOKE the closure. Without the bug010 fix
// this hit either a struct-layout mismatch at compile or — if it
// somehow linked — got a bogus closure pointer. Asserting on a side-effect
// the stored closure produces is what catches a wrong-closure regression
// (which `.has()` / `.size` checks would silently let through).
//
// `get()` returns `V | null`, so the retrieved closure needs `!` before it can
// be invoked — calling a possibly-null callee is now a checker error (tsc
// ts2722 parity). The bug shape is unchanged: what is under test is that the
// closure survives the round-trip through the map.
type IntCmp = (a: int32, b: int32) => int32;

test "bug010: Map<string, FunctionType> round-trip — retrieve and invoke" {
	const cmps: Map<string, IntCmp> = new Map<string, IntCmp>();
	cmps.set("min", (a, b) => (a < b ? a : b) as int32);
	cmps.set("max", (a, b) => (a > b ? a : b) as int32);
	const minFn = cmps.get("min")!;
	const maxFn = cmps.get("max")!;
	assert minFn(3, 7) == 3;
	assert maxFn(3, 7) == 7;
	assert minFn(10, 2) == 2;
	assert maxFn(10, 2) == 10;
}
