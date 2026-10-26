// @stdout: tailrec-closure r=5000000-5000000-5000000-5000000
// A self-recursive routine bound to a const gets the same tail-call lowering as
// a function declaration. Two halves had to land together: the checker now takes
// the symbol's type from the routine's own signature (reference parity —
// semProcAux sets s.typ before the body), without which the C backend emitted a
// direct call on an msClosure; and the lowering accepts the const binding as a
// tail-call target, expression-bodied arrows included.

const f = (n: int64, acc: int64): int64 => n <= 0 ? acc : f(n - 1, acc + 1);

const g = (n: int64, acc: int64): int64 => {
	if (n <= 0) return acc;
	return g(n - 1, acc + 1);
};

const h = function (n: int64, acc: int64): int64 {
	if (n <= 0) return acc;
	return h(n - 1, acc + 1);
};

function outer(): int64 {
	const k = (n: int64, acc: int64): int64 => {
		if (n <= 0) return acc;
		return k(n - 1, acc + 1);
	};
	return k(5000000, 0);
}

console.log("tailrec-closure r=" + f(5000000, 0).toString() + "-" + g(5000000, 0).toString() + "-" + h(5000000, 0).toString() + "-" + outer().toString());
