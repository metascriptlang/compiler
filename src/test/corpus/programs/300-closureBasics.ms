// Parity program — the closure floor: capture, invoke, pass, return, nest.
// Lambda lifting is the machinery under every arm of this file; a regression
// here localizes before it becomes a 30x mystery.

type IntFn = (x: int64) => int64;

function apply(f: IntFn, v: int64): int64 {
	return f(v);
}

function makeAdder(base: int64): IntFn {
	return (x: int64): int64 => x + base;
}

function main(): void {
	const ten: int64 = 10;
	const addTen = (x: int64): int64 => x + ten;
	console.log("captureLocal=" + addTen(5).toString());

	console.log("captureParam=" + apply((x: int64): int64 => x * 2, 21).toString());

	const add3 = makeAdder(3);
	const add7 = makeAdder(7);
	console.log("escape3=" + add3(1).toString());
	console.log("escape7=" + add7(1).toString());
	console.log("escapeAgain=" + add3(10).toString());

	const mul = (a: int64): IntFn => (b: int64): int64 => a * b;
	const double = mul(2);
	console.log("curry=" + double(21).toString());

	const prefix = "v";
	const outer = (n: int64): string => {
		const mid = n + ten;
		const inner = (): string => prefix + mid.toString();
		return inner();
	};
	console.log("nested=" + outer(5));

	const name = "closure";
	const greet = (): string => "hello " + name;
	console.log("string=" + greet());
}
main();
