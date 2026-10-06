// @stdout: negative|negative|positive|negative|negative
// @exit: 0
function zeroSign(value: float64): string {
	return 1.0 / value < 0.0 ? "negative" : "positive";
}
const wide: float64 = -0.0;
const narrow: float32 = -0.0;
const positive: float64 = -wide;
const alias = wide;
console.log([zeroSign(wide), zeroSign(narrow as float64), zeroSign(positive), zeroSign(alias), zeroSign(-0.0)].join("|"));
