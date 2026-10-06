// Parity program — a variable declared AFTER a loop whose body was captured by
// a closure must keep its own storage, even when it spells the same name as the
// captured loop-local. The per-iteration env belongs to the iteration that
// created it; nothing past the loop boundary may resolve through it.
//
// The JS lane is the oracle here: lambda lifting is a C-backend pass, so JS
// reads every binding directly and cannot express the defect.

type Thunk = () => string;

function shadowedAfterLoop(): string {
	const names: string[] = ["a", "b", "c"];
	const fs: Thunk[] = [];
	for (const j of names) {
		fs.push(() => { return j; });
	}
	let out = "";
	let ci = 0;
	while (ci < names.length) {
		const j = names[ci];
		out = out + j;
		ci = ci + 1;
	}
	let cl = "";
	for (const f of fs) {
		cl = cl + f();
	}
	return out + "|" + cl;
}

function shadowedBetweenLoops(): string {
	const src: string[] = ["p", "q"];
	const fs: Thunk[] = [];
	for (const v of src) {
		fs.push(() => { return v; });
	}
	let mid = "";
	for (const v of src) {
		mid = mid + v + v;
	}
	let tail = "";
	for (const f of fs) {
		tail = tail + f();
	}
	return mid + "|" + tail;
}

function shadowedNumeric(): int64 {
	const xs: int64[] = [1, 2, 3];
	const fns: (() => int64)[] = [];
	for (const n of xs) {
		fns.push((): int64 => n);
	}
	let sum: int64 = 0;
	let i = 0;
	while (i < xs.length) {
		const n = xs[i] * 10;
		sum = sum + n;
		i = i + 1;
	}
	for (const f of fns) {
		sum = sum + f();
	}
	return sum;
}

function nestedLoopShadow(): string {
	const outer: string[] = ["m", "n"];
	const fs: Thunk[] = [];
	for (const a of outer) {
		fs.push(() => { return a; });
		let inner = "";
		for (const a2 of outer) {
			inner = inner + a2;
		}
		fs.push(() => { return inner; });
	}
	let acc = "";
	for (const f of fs) {
		acc = acc + f() + ".";
	}
	return acc;
}

function main(): void {
	console.log("shadowedAfterLoop=" + shadowedAfterLoop());
	console.log("shadowedBetweenLoops=" + shadowedBetweenLoops());
	console.log("shadowedNumeric=" + shadowedNumeric().toString());
	console.log("nestedLoopShadow=" + nestedLoopShadow());
}
main();
