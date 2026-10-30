// @stdout: 0.5|1|0.5|3|-1.5|2
function parentAlpha(first: boolean, up: float32, own: float32): float32 {
	return (first ? 1.0 : up) * own;
}
function literalSecond(first: boolean, up: float32, own: float32): float32 {
	return own * (first ? up : 2.0);
}
function negated(x: float32): float32 { return -3.0 * x; }
console.log([
	parentAlpha(true, 0.25, 0.5),
	parentAlpha(false, 2, 0.5),
	literalSecond(true, 1, 0.5),
	literalSecond(false, 1, 1.5),
	negated(0.5),
	parentAlpha(false, 1, 2),
].join("|"));
