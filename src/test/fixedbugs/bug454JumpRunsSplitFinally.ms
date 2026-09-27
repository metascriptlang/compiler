// bug454 — break/continue nested in an if skipped the finally of a split try
//
// Symptom:    on C, `while (i < 3) { try { yield i; if (i == 1) break; }
//             finally { log(i); } i++; }` never ran the finally on the break
//             path (generator and async alike); a nested `continue` skipped it
//             too. JS was correct.
// Root cause: src/transform/lowering/generatorLower.ms ran the crossed
//             finallies only for a break/continue at the top of a split
//             statement list; one nested in a yield-free if became a bare
//             state jump.
// Fix:        every break, continue and generator return, at any depth, runs
//             the split finallies it crosses before its state jump.
//
// Guarded end-to-end by corpus/programs/922-asyncAwaitJoins.ms.

let b454Log: string = "";

function* b454Gen(): Iterator<int32> {
	let i: int32 = 0;
	while (i < 3) {
		try {
			yield i;
			if (i == 1) break;
		} finally {
			b454Log = b454Log + "f" + i.toString() + ";";
		}
		i++;
	}
}

async function b454Work(x: int32): Promise<int32> {
	return x * 2;
}

async function b454Async(): Promise<int32> {
	let i: int32 = 0;
	while (i < 5) {
		try {
			const v = await b454Work(i);
			if (v >= 4) break;
			if (v == 0) {
				i++;
				continue;
			}
		} finally {
			b454Log = b454Log + "a" + i.toString() + ";";
		}
		i++;
	}
	return i;
}

test "bug454: a nested break in a generator runs the finally it leaves" {
	b454Log = "";
	let out: string = "";
	for (const v of b454Gen()) out = out + v.toString();
	assert out == "01";
	assert b454Log == "f0;f1;";
}

test "bug454: nested break and continue in an async loop run the finally" {
	b454Log = "";
	const r = await b454Async();
	assert r == 2;
	assert b454Log == "a1;a1;a2;";
}
