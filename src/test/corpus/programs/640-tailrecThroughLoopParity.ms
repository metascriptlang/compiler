// @stdout: tailrec-loop r=5000056-2000000
// A self tail call inside a while / do-while body IS lowered: the wrapper
// carries a label and the rewrite continues the wrapper, not the inner loop
// (Nim transformLoopBody model — labeled jump past the inner loop). Depth 5M
// overflows the stack if the call is left as real recursion; 638 pins the
// value so a continue that binds the wrong loop cannot pass either.

function f(n: int64, acc: int64): int64 {
	let steps: int64 = 0;
	while (steps < 5) {
		steps += 1;
		if (steps === 3 && n > 0) {
			return f(n - 1, acc + 1);
		}
	}
	return acc + steps * 10 + 6;
}

function g(n: int64, acc: int64): int64 {
	let i: int64 = 0;
	do {
		i += 1;
		if (i === 2 && n > 0) {
			return g(n - 1, acc + 2);
		}
	} while (i < 3);
	return acc;
}

console.log("tailrec-loop r=" + f(5000000, 0).toString() + "-" + g(1000000, 0).toString());
