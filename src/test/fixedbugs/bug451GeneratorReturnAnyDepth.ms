// bug451 — a bare or nested `return` in a generator broke the C build
//
// Symptom:    on C, `yield 1; return;` crashed msc with a segfault and
//             `if (n > 0) return;` emitted a bare C `return;` in the function
//             that returns the iterator result, so C did not compile. JS was
//             correct.
// Root cause: src/transform/lowering/generatorLower.ms rewrote only the
//             top-level returns of the body and read the missing argument of
//             a bare one.
// Fix:        the state splitter turns every return, at any depth, into
//             `$state = -1; return done`, running each split finally it leaves.
//
// Guarded end-to-end by corpus/programs/921-generatorStatements.ms.

function* b451Bare(): Iterator<int32> {
	yield 1;
	return;
}

function* b451InIf(n: int32): Iterator<int32> {
	yield 1;
	if (n > 0) return;
	yield 2;
}

function* b451InLoop(): Iterator<int32> {
	let i: int32 = 0;
	while (true) {
		yield i;
		i++;
		if (i == 3) return;
	}
}

let b451Log: string = "";

function* b451ThroughFinally(stop: boolean): Iterator<int32> {
	try {
		yield 1;
		if (stop) return;
		yield 2;
	} finally {
		b451Log = b451Log + "fin;";
	}
	yield 3;
}

test "bug451: a bare return after a yield ends the generator" {
	let out: string = "";
	for (const v of b451Bare()) out = out + v.toString();
	assert out == "1";
}

test "bug451: a return nested in an if ends the generator" {
	let out: string = "";
	for (const v of b451InIf(1)) out = out + v.toString();
	for (const v of b451InIf(0)) out = out + v.toString();
	assert out == "112";
}

test "bug451: a return nested in a loop ends the generator" {
	let out: string = "";
	for (const v of b451InLoop()) out = out + v.toString();
	assert out == "012";
}

test "bug451: a return inside a split try runs its finally once" {
	b451Log = "";
	let out: string = "";
	for (const v of b451ThroughFinally(true)) out = out + v.toString();
	for (const v of b451ThroughFinally(false)) out = out + v.toString();
	assert out == "1123";
	assert b451Log == "fin;fin;";
}
