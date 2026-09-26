// bug465 — a spawn handle used other than by `await` vanished on C
//
// Symptom:    on C, `const w = spawn(fn); useIt(w);` failed to compile with
//             "use of undeclared identifier 'w'"; so did `const n = await w;`
//             inside an async function once its locals stayed in their state.
// Root cause: src/transform/lowering/awaitLower.ms replaced every
//             `const h = spawn(fn)` with an await slot and dropped `h`,
//             assuming the only use of a handle is a blocking `await h` in the
//             same function; a handle passed on, stored, or awaited by an
//             async function's state machine still named `h`.
// Fix:        the slot replaces a handle only when every use of it in its
//             function is `await h`; the per-function state is kept on a
//             stack, so a nested function does not reset its parent's.

function b465UseIt(p: Promise<int32>): int32 {
	return await p;
}

function b465Passed(): int32 {
	const w = spawn((): int32 => 1);
	return b465UseIt(w);
}

async function b465InAsync(): Promise<int32> {
	const w = spawn((): int32 => 4);
	const n = await w;
	return n + 1;
}

function b465AwaitOnly(): int32 {
	const h = spawn((): int32 => 2);
	const g = (): int32 => 3;
	const v = await h;
	return v + g();
}

test "bug465: a spawn handle passed to a function keeps its binding" {
	assert b465Passed() == 1;
}

test "bug465: a spawn handle awaited in an async function keeps its binding" {
	assert await b465InAsync() == 5;
}

test "bug465: a spawn handle awaited in its own function still works across a nested closure" {
	assert b465AwaitOnly() == 5;
}
