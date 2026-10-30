// @stdout: -Infinity Infinity 9 1 3 7
// @stdout: 2 1 NaN NaN 5 4
// @stdout: true true
// @stdout: 7 2 2 NaN NaN NaN NaN
function pick(xs: float64[]): float64 {
	return Math.max(...xs);
}

function low(xs: float64[]): float64 {
	return Math.min(...xs);
}

const none: float64[] = [];
const a: int32 = 2;
const b: int32 = 7;
const m: int32 = Math.max(a, b);
console.log(Math.max(), Math.min(), pick([3, 9, 1]), low([3, 9, 1]), Math.max(1, 2, 3), m);
console.log(Math.max(1, 2), Math.min(1, 2), Math.max(1, NaN, 3), Math.min(NaN, 2), Math.max(...[5, 4]), Math.min(...[5, 4]));
console.log(pick(none) == -Infinity, low(none) == Infinity);
console.log(Math.max(a, b, 5), Math.min(a, b, 5), Math.min(a, b), Math.max(NaN, 2.5), Math.max(2.5, NaN), Math.min(NaN, 2.5), Math.min(2.5, NaN));
