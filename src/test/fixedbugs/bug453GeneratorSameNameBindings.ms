// bug453 — two same-named bindings of a generator shared one hoisted local
//
// Symptom:    on C, `if (f) { const x: string = "str"; yield x; } else
//             { const x: int32 = 42; yield x.toString(); }` in a generator
//             did not compile (`assigning to 'msString' from 'int'`); two
//             sequential loops each declaring `const x` of another type
//             failed the same way. JS was correct.
// Root cause: src/transform/lowering/generatorLower.ms hoists locals into
//             the iterator env by name, so both bindings became one field
//             typed by the first.
// Fix:        the locals a state machine hoists are keyed by symbol, one
//             hoisted slot per binding.
//
// Guarded end-to-end by corpus/programs/921-generatorStatements.ms.

function* b453Branches(flag: boolean): Iterator<string> {
	if (flag) {
		const x: string = "str";
		yield x;
	} else {
		const x: int32 = 42;
		yield x.toString();
	}
	yield "end";
}

function* b453Loops(): Iterator<string> {
	let i: int32 = 0;
	while (i < 2) {
		const x: string = "s" + i.toString();
		yield x;
		i++;
	}
	let j: int32 = 0;
	while (j < 2) {
		const x: int32 = j * 10;
		yield x.toString();
		j++;
	}
}

test "bug453: same-named branch bindings of different types" {
	let out: string = "";
	for (const v of b453Branches(true)) out = out + v + ",";
	for (const v of b453Branches(false)) out = out + v + ",";
	assert out == "str,end,42,end,";
}

test "bug453: same-named loop bindings of different types" {
	let out: string = "";
	for (const v of b453Loops()) out = out + v + ",";
	assert out == "s0,s1,0,10,";
}
