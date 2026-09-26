// bug457 — a captured variable read only by a switch discriminant was not captured
//
// Symptom:    on C, a closure whose only use of an outer `k` was `switch (k)`
//             inside a loop failed to compile (`use of undeclared identifier
//             'k'`); a generator switching on its parameter failed the same
//             way. JS was correct.
// Root cause: the SwitchStmt arms of detectAllWalk
//             (src/transform/lowering/lambdaLiftingDetect.ms) and walkLift
//             (lambdaLifting.ms) visited the cases but not the discriminant.
// Fix:        both walks visit the discriminant and the case tests.
//
// Guarded end-to-end by corpus/programs/921-generatorStatements.ms.

function b457Loop(k: int32): () => string {
	let s: int32 = 0;
	const f = (): string => {
		while (true) {
			if (s == 0) {
				switch (k) {
					case 1:
						s = 1;
						break;
					default:
						s = 2;
						break;
				}
			} else {
				return s.toString();
			}
		}
	};
	return f;
}

function* b457Gen(k: int32): Iterator<string> {
	switch (k) {
		case 1:
			yield "one";
			break;
		default:
			yield "other";
	}
}

test "bug457: a closure switching on a captured variable" {
	assert b457Loop(1)() == "1";
	assert b457Loop(7)() == "2";
}

test "bug457: a generator switching on its parameter" {
	let out: string = "";
	for (const v of b457Gen(1)) out = out + v;
	for (const v of b457Gen(3)) out = out + v;
	assert out == "oneother";
}
