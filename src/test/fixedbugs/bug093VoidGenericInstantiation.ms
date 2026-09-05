// bug093 — generic instantiated at T=void emitted invalid C
//
// Symptom:    `run<T>(fn: () => T): T` called with a void-bodied arrow
//             instantiates at T=void (correct type since the void-arrow
//             return fix), but the C body declared a `void*` local, assigned
//             the void call into it, and returned it from a void function:
//             clang `assigning to 'void *' from incompatible type 'void'`
//             + `-Wreturn-mismatch`. Blocked neon createRoot (4 tests).
// Root cause: genVarDecl mapped a genuinely void-typed local to `void*`
//             storage (a guard meant only for null-literal inits), and
//             genReturnStmt emitted `return <snippet>` regardless of the
//             function's void return. Reference discards void expressions
//             (isEmptyType) — MS must too, since TS allows `const r = fn()`
//             and `return r` at T=void.
// Fix:        codegen/c/statements.ms — a Void-typed VarDecl emits its
//             initializer for effect only (no storage, raise check kept);
//             a void return argument emits the expression as a statement
//             (identifiers emit nothing — no storage exists) then `return;`.

// float64 (not the inferred int32): the callbacks below take `tag: number`,
// so `bug093Hits + tag` is a double — the repro shape is T=void, not numerics.
let bug093Hits: float64 = 0;

function bug093RunId<T>(fn: (tag: number) => T): T {
	const result = fn(7);
	return result;
}

function bug093RunDirect<T>(fn: (tag: number) => T): T {
	return fn(3);
}

function bug093Root<T>(fn: (dispose: () => void) => T): T {
	const cleanup = () => { bug093Hits = bug093Hits + 100; };
	const result = fn(cleanup);
	return result;
}

test "bug093: T=void instance with identifier return runs the callback" {
	bug093Hits = 0;
	bug093RunId((tag: number) => { bug093Hits = bug093Hits + tag; });
	assert bug093Hits === 7;
}

test "bug093: T=void instance with direct call return runs the callback" {
	bug093Hits = 0;
	bug093RunDirect((tag: number) => { bug093Hits = bug093Hits + tag; });
	assert bug093Hits === 3;
}

test "bug093: createRoot shape — void body receiving a dispose callback" {
	bug093Hits = 0;
	bug093Root((dispose: () => void) => {
		bug093Hits = bug093Hits + 1;
		dispose();
	});
	assert bug093Hits === 101;
}

test "bug093: control — the same generics at T=number still return values" {
	bug093Hits = 0;
	const a = bug093RunId((tag: number) => tag + 35);
	const b = bug093RunDirect((tag: number) => tag * 2);
	const c = bug093Root((dispose: () => void) => { dispose(); return 9; });
	assert a === 42;
	assert b === 6;
	assert c === 9;
	assert bug093Hits === 100;
}
