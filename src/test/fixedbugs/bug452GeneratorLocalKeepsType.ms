// bug452 — a for-of inside a generator did not compile on C
//
// Symptom:    on C, `for (const x of xs) yield x;` in a generator emitted
//             `$len = MS_NIL` into an int32 env field and the C compile
//             failed; the same for string[] and for a nested for-of. JS was
//             correct.
// Root cause: src/transform/lowering/generatorLower.ms typed a hoisted local
//             only from the declaration's nodeType or initializer (the for-of
//             temps carry only a symbol), walked only block/if/while bodies,
//             and started every hoisted local at null.
// Fix:        the type falls back to the declaration symbol's type, the walk
//             covers every statement, and a hoisted local starts at its
//             type's zero value.
//
// Guarded end-to-end by corpus/programs/921-generatorStatements.ms.

function* b452Ints(xs: int32[]): Iterator<int32> {
	for (const x of xs) {
		yield x;
	}
}

function* b452Strings(xs: string[]): Iterator<string> {
	for (const x of xs) {
		yield x;
	}
}

function* b452Pairs(xs: string[]): Iterator<string> {
	for (const x of xs) {
		for (const y of xs) {
			yield x + y;
		}
	}
}

test "bug452: for-of over int32[] inside a generator" {
	let sum: int32 = 0;
	for (const v of b452Ints([1, 2, 3])) sum = sum + v;
	assert sum == 6;
}

test "bug452: for-of over string[] inside a generator" {
	let out: string = "";
	for (const v of b452Strings(["a", "b"])) out = out + v;
	assert out == "ab";
}

test "bug452: nested for-of inside a generator" {
	let out: string = "";
	for (const v of b452Pairs(["a", "b"])) out = out + v + ",";
	assert out == "aa,ab,ba,bb,";
}
