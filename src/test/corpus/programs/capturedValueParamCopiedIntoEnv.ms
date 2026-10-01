// @stdout: env copy 9 40 3 | loop 4 5 | rebound 2 4 1 1 caller 2 | nested 7 | churn 32
// @xfail(raiser): raiser runtime error: expected an object, got value kind Int

class Box {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

function sumLater(items: Vec<Box>): () => int32 {
	return (): int32 => {
		let s: int32 = 0;
		for (const b of items) { s = s + b.n; }
		return s + (items.length as int32);
	};
}

function escaping(): () => int32 {
	let local: Vec<Box> = [new Box(1), new Box(2), new Box(3)];
	return sumLater(local);
}

function readNow(items: Vec<Box>): int32 {
	const at = (k: int32): int32 => items[k].n;
	return at(0) + at(2);
}

function perIteration(v: Vec<int32>): (() => int32)[] {
	let fs: (() => int32)[] = [];
	for (let i: int32 = 0; i < 2; i++) { fs.push((): int32 => v[i] + (v.length as int32)); }
	return fs;
}

function loopOverParam(): string {
	let local: Vec<int32> = [1, 2, 3];
	const fs = perIteration(local);
	return `${fs[0]()} ${fs[1]()}`;
}

function rebound(v: Vec<int32>): string {
	const len = (): int32 => v.length as int32;
	const before = len();
	v = [9, 9, 9, 9];
	const after = len();
	const reset = (): void => { v = [5]; };
	reset();
	return `${before} ${after} ${v.length} ${len()}`;
}

function nested(v: Vec<Box>): int32 {
	const outer = (): int32 => {
		const inner = (): int32 => v[0].n + v[1].n;
		return inner();
	};
	return outer();
}

function churn(): int32 {
	let keep: Vec<Box>[] = [];
	for (let i: int32 = 0; i < 32; i++) { keep.push([new Box(100 + i), new Box(200 + i)]); }
	return keep.length as int32;
}

function run(): string {
	const later = escaping();
	const kept = churn();
	let src: Vec<Box> = [new Box(10), new Box(20), new Box(30)];
	let w: Vec<int32> = [1, 2];
	const pair: Vec<Box> = [new Box(3), new Box(4)];
	const head = `env copy ${later()} ${readNow(src)} ${src.length}`;
	const loop = `loop ${loopOverParam()}`;
	const back = `rebound ${rebound(w)} caller ${w.length}`;
	return `${head} | ${loop} | ${back} | nested ${nested(pair)} | churn ${kept}`;
}

console.log(run());
