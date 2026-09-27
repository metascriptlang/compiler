// bug458 — the js target rejected `.then((value) => ...)`
//
// Symptom:    with --target=js, `work(5).then((v: int32): void => ...)`
//             failed type checking ("Argument type mismatch in 'then' arg 0:
//             got function, expected function"). C accepted it.
// Root cause: std/core/promise/index.jms declared `then(fn: () => T):
//             Promise<T>` for its own spawn twin instead of the documented
//             `then(callback: (value: T) => void): Promise<void>` of the C
//             prelude.
// Fix:        the js prelude declares the documented then; spawn reaches the
//             native then through a private extern.

async function b458Work(x: int32): Promise<int32> {
	return x * 2;
}

let b458Seen: int32 = 0;

function b458Record(v: int32): void {
	b458Seen = v;
}

test "bug458: then with an arrow receives the fulfilled value" {
	b458Seen = 0;
	const w = b458Work(5);
	const p = w.then((v: int32): void => { b458Seen = v; });
	await p;
	assert b458Seen == 10;
}

test "bug458: then with a named function receives the fulfilled value" {
	b458Seen = 0;
	const w = b458Work(7);
	await w.then(b458Record);
	assert b458Seen == 14;
}
