// @stdout: tailrec-rebind r=-994
// A let binding can be reassigned after the closure is captured, so it is not
// a self-tail-call target: the call must go through the binding at call time.
// Lowering it into a loop froze the initial routine and printed 15 here.

const dummy = (n: int32, acc: int32): int32 => acc - 999;

let f = (n: int32, acc: int32): int32 => {
	if (n <= 0) return acc;
	return f(n - 1, acc + n);
};

const g = f;
f = dummy;
console.log("tailrec-rebind r=" + g(5, 0).toString());
