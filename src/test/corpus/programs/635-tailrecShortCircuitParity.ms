// @stdout: tailrec-shortcircuit r=
// `a || f(x)` and `a && f(x)` leave f(x) in tail position — the operator only
// decides whether the call happens, nothing runs after it. The left operand is
// evaluated once into a temp, so a side-effecting guard stays sound.

let probes: int64 = 0;

function bump(n: int64): boolean {
	probes += 1;
	return n <= 0;
}

function anyTrue(n: int64): boolean {
	return bump(n) || anyTrue(n - 1);
}

function allTrue(n: int64): boolean {
	return n > 0 && allTrue(n - 1);
}

console.log("tailrec-shortcircuit r=" + anyTrue(3000000).toString() + "-" + allTrue(3000000).toString() + "-" + probes.toString());
