// @stdout: number 4
// @stdout: same 3
// @stdout: method 5
// note: a function-local binding without an annotation holds the value of an unchecked `as` out of a number-literal union, to number or to the same union.

type Wide = 1 | 2 | 3 | 4;
type Odd = 1 | 3 | 5;

function readWide(x: Wide): Wide { return x; }

class Box {
	odd: Odd = 5;
	read(): number {
		const v = this.odd as number;
		return v;
	}
}

function main(): void {
	const n = readWide(4) as number;
	console.log("number", n);
	const s = readWide(3) as Wide;
	console.log("same", s);
	console.log("method", new Box().read());
}
main();
