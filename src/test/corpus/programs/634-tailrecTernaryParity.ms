// @stdout: tailrec-ternary r=
// A tail call in a ternary arm is still a tail call. tailCallLower expands the
// return-position ternary into if/return itself: conditionalExprLower runs after
// it on C and skips ternaries entirely on JS, so neither backend would otherwise
// see the shape and both blew the stack.

function loop(n: int64, acc: int64): int64 {
	return n <= 0 ? acc : loop(n - 1, acc + 1);
}

function nest(n: int64, acc: int64): int64 {
	return n <= 0 ? acc : (n % 2 === 0 ? nest(n - 1, acc + 2) : nest(n - 1, acc + 1));
}

function grow(n: int64, s: string): string {
	return n <= 0 ? s : grow(n - 1, s.slice(0, 1) + "y");
}

console.log("tailrec-ternary r=" + loop(5000000, 0).toString() + "-" + nest(5000000, 0).toString() + "-" + grow(200000, "y").length.toString());
