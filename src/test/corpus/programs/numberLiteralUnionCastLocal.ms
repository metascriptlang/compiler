// @stdout: call 3
// @stdout: param 2
// @stdout: nested 1
// @stdout: let 3 2
// note: a function-local binding without an annotation holds the value of a checked `as` into a number-literal union, whether the operand is a call, a parameter or a parenthesised cast in a nested block.

type Wide = 1 | 2 | 3 | 4;
type Narrow = 1 | 2 | 3;

function readWide(x: Wide): Wide { return x; }

function fromParam(w: Wide): void {
	const n = w as Narrow;
	console.log("param", n);
}

function main(): void {
	const b = readWide(3) as Narrow;
	console.log("call", b);
	fromParam(2);
	if (b == 3) {
		const c = (readWide(1) as Narrow);
		console.log("nested", c);
	}
	let e = readWide(3) as Narrow;
	const kept = e;
	e = readWide(2) as Narrow;
	console.log("let", kept, e);
}
main();
