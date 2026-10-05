// Parity program — captured-variable mutation: the env must share ONE binding
// with the declaring scope, and drc/orc/danger/js must agree on every
// observation, including closures minted per loop iteration.

type Thunk = () => int64;

function main(): void {
	let count: int64 = 0;
	const bump = (): void => { count = count + 1; };
	bump();
	bump();
	console.log("afterTwoBumps=" + count.toString());
	count = 100;
	bump();
	console.log("outerWriteSeen=" + count.toString());

	const makeCounter = (): Thunk => {
		let n: int64 = 0;
		return (): int64 => { n = n + 1; return n; };
	};
	const c1 = makeCounter();
	const c2 = makeCounter();
	console.log("c1a=" + c1().toString());
	console.log("c1b=" + c1().toString());
	console.log("c2a=" + c2().toString());

	const fns: Thunk[] = [];
	for (let i: int64 = 0; i < 3; i = i + 1) {
		fns.push((): int64 => i);
	}
	let out = "";
	for (const f of fns) {
		out = out + f().toString() + ",";
	}
	console.log("loopCapture=" + out);

	let acc = "";
	const append = (piece: string): void => { acc = acc + piece; };
	append("a");
	append("b");
	append("c");
	console.log("acc=" + acc);
}
main();
