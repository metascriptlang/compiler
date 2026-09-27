// bug456 — an await ending a branch or a loop body crashed the async function
//
// Symptom:    on C, `if (c) { await work(1); }` with c false, and
//             `while (i < 3) { i++; await work(i); }` on its first pass,
//             panicked with a member access within a null msFutureBase; an
//             await ending a match arm crashed the same way. JS was correct.
// Root cause: src/transform/lowering/generatorLower.ms made the state after a
//             trailing yield the statement list's exit state, which other
//             paths also enter, and the async bridge reads the awaited future
//             at the entry of that state.
// Fix:        every yield resumes in a state of its own, which then moves on
//             to the list's exit.
//
// Guarded end-to-end by corpus/programs/922-asyncAwaitJoins.ms.

async function b456Work(x: int32): Promise<int32> {
	return x * 2;
}

let b456Log: string = "";

async function b456IfTail(c: boolean): Promise<void> {
	if (c) {
		await b456Work(1);
	}
	b456Log = b456Log + "if;";
}

async function b456LoopTail(): Promise<int32> {
	let i: int32 = 0;
	let s: int32 = 0;
	while (i < 3) {
		i++;
		s = s + i;
		await b456Work(i);
	}
	return s;
}

async function b456MatchTail(k: int32): Promise<void> {
	match (k) {
		1 => { await b456Work(10); },
		_ => { await b456Work(100); },
	}
	b456Log = b456Log + "m" + k.toString() + ";";
}

test "bug456: an await ending an if branch, with the branch not taken" {
	b456Log = "";
	await b456IfTail(false);
	await b456IfTail(true);
	assert b456Log == "if;if;";
}

test "bug456: an await ending a loop body" {
	const s = await b456LoopTail();
	assert s == 6;
}

test "bug456: an await ending a match arm" {
	b456Log = "";
	await b456MatchTail(1);
	await b456MatchTail(2);
	assert b456Log == "m1;m2;";
}
