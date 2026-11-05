// @stdout: 1 2 -2 1.5 3 0
// note: an integer left of `%` with a number or float on the right takes the floating remainder, as `+` takes the wider type; on C it went to the integer `%`, which C refuses for a double operand, so the program did not compile. An integer right side keeps the integer remainder.

function lengthModulo(xs: Readonly<uint8[]>, per: number): number {
	return xs.length % per;
}

function signedModulo(a: int32, b: float64): number {
	return a % b;
}

const bytes: uint8[] = [1, 2, 3, 4, 5, 6, 7];
const whole: int64 = 7;
console.log(`${lengthModulo(bytes, 2)} ${lengthModulo(bytes, 2.5)} ${signedModulo(-7, 2.5)} ${signedModulo(7, 5.5) % 2.5} ${whole % 4} ${bytes.length % 7}`);
