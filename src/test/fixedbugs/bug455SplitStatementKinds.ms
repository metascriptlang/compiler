// bug455 — a yield inside do-while, switch, match or finally was dropped
//
// Symptom:    on C, a generator with `do { yield i; i++; } while (i < 3)`
//             printed only what followed the loop; a yield in a switch case
//             or a match arm was dropped, and one in a finally body vanished.
//             JS was correct.
// Root cause: src/transform/lowering/generatorLower.ms split only block, if,
//             while and try statements (and a try only when its finally was
//             yield-free), passing every other statement through with the
//             yield still inside.
// Fix:        do-while, switch and a finally that yields are split into
//             states, and a statement the splitter cannot split is reported
//             instead of passed through.
//
// Guarded end-to-end by corpus/programs/921-generatorStatements.ms.

function* b455DoWhile(): Iterator<int32> {
	let i: int32 = 0;
	do {
		yield i;
		i++;
	} while (i < 3);
	yield 99;
}

function* b455Switch(k: int32): Iterator<string> {
	switch (k) {
		case 1:
			yield "one";
			break;
		default:
			yield "other";
	}
	yield "end";
}

function* b455Match(k: int32): Iterator<string> {
	match (k) {
		1 => { yield "one"; },
		_ => { yield "other"; },
	}
	yield "end";
}

function* b455Finally(): Iterator<string> {
	try {
		yield "a";
	} finally {
		yield "f";
	}
	yield "end";
}

test "bug455: a yield inside do-while" {
	let out: string = "";
	for (const v of b455DoWhile()) out = out + v.toString() + ",";
	assert out == "0,1,2,99,";
}

test "bug455: a yield inside a switch case" {
	let out: string = "";
	for (const v of b455Switch(1)) out = out + v + ",";
	for (const v of b455Switch(2)) out = out + v + ",";
	assert out == "one,end,other,end,";
}

test "bug455: a yield inside a match arm" {
	let out: string = "";
	for (const v of b455Match(1)) out = out + v + ",";
	for (const v of b455Match(5)) out = out + v + ",";
	assert out == "one,end,other,end,";
}

test "bug455: a yield inside a finally body" {
	let out: string = "";
	for (const v of b455Finally()) out = out + v + ",";
	assert out == "a,f,end,";
}
