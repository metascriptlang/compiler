// @stdout: tailrec-nested r=56-5000000
// Two halves. (1) A self tail call inside a while body is lowered via the
// labeled wrapper (continue __tcl) — a rewrite whose continue binds the INNER
// loop instead skips the per-call reset of `steps` and yields 53 instead of
// 56. This pins that binding; 640 pins the depth behavior.
// (2) A tail call behind bare nested blocks and a braceless if must be lowered
// by the generic mapChildren recursion — 5M depth overflows the stack if not.

function f(n: int64, acc: int64): int64 {
	let steps: int64 = 0;
	while (steps < 5) {
		steps += 1;
		if (steps == 3 && n > 0) {
			return f(n - 1, acc + steps);
		}
	}
	return acc + steps * 10;
}

function g(n: int64, acc: int64): int64 {
	if (n <= 0) return acc;
	{
		{
			return g(n - 1, acc + 1);
		}
	}
}

console.log("tailrec-nested r=" + f(2, 0).toString() + "-" + g(5000000, 0).toString());
