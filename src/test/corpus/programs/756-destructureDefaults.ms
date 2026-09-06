// Parity program — a destructuring default fires on a null field and on an index
// past the source's length, and stays out of the way when the source carries a
// value. The binding sheds null, so `x` is usable as a plain int32 afterwards.
//
// @stdout: 5,7,9,3,14
// @exit: 0

interface P { x: int32 | null; y: int32 | null; }

function main(): void {
	const p: P = { x: null, y: 7 };
	const { x = 5, y = 6 } = p;

	const short: int32[] = [3];
	const [a = 8, b = 9] = short;

	const sum: int32 = x + b - a + 3;
	console.log(x.toString() + "," + y.toString() + "," + b.toString() + "," + a.toString() + "," + sum.toString());
}

main();
