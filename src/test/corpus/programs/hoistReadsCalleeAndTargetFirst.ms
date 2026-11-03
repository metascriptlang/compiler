// @stdout: fa 1 | put old 1 | 13,0,0 2 | idx,map 0,map 1 | 13 7 | 3,0 | await: fa 5 | put old 5 | 5,0,0 2

function* gen(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i++) yield i;
}

const trail: string[] = [];

function fa(v: number): number {
	trail.push(`fa ${v}`);
	return v;
}

function fb(v: number): number {
	trail.push(`fb ${v}`);
	return v;
}

class Box {
	name: string;
	constructor(name: string) {
		this.name = name;
	}
	put(v: number): number {
		trail.push(`put ${this.name} ${v}`);
		return v;
	}
}

let fn: (v: number) => number = fa;
fn(gen(2).map((x: int32): number => { fn = fb; return x; }).reduce((p: number, q: number): number => p + q, 0));
let bx = new Box("old");
bx.put(gen(2).map((x: int32): number => { bx = new Box("new"); return x; }).reduce((p: number, q: number): number => p + q, 0));

let i: number = 0;
const arr: number[] = [0, 0, 0];
arr[i++] = gen(3).map((x: int32): number => { i = 2; return x; }).reduce((p: number, q: number): number => p + q, 10);
trail.push(`${arr.join(",")} ${i}`);

const seen: string[] = [];
function idx(): number {
	seen.push("idx");
	return 0;
}
const arr2: number[] = [0];
arr2[idx()] = gen(2).map((x: int32): number => { seen.push(`map ${x}`); return x; }).reduce((p: number, q: number): number => p + q, 10);
trail.push(seen.join(","));

let arr3: number[] = [0, 0, 0];
const keep = arr3;
arr3[0] = gen(3).map((x: int32): number => { arr3 = [7, 7, 7]; return x; }).reduce((p: number, q: number): number => p + q, 10);
trail.push(`${keep[0]} ${arr3[0]}`);

const rows: number[][] = [[0], [0]];
let k: number = 0;
rows[k][0] = gen(3).map((x: int32): number => { k = 1; return x; }).reduce((p: number, q: number): number => p + q, 0);
trail.push(`${rows[0][0]},${rows[1][0]}`);

async function later(v: number, after: () => void): Promise<number> {
	after();
	return v;
}

async function viaAwait(): Promise<string[]> {
	const out: string[] = [];
	fn = fa;
	fn(await later(5, (): void => { fn = fb; }));
	bx = new Box("old");
	bx.put(await later(5, (): void => { bx = new Box("new"); }));
	let j: number = 0;
	const cells: number[] = [0, 0, 0];
	cells[j++] = await later(5, (): void => { j = 2; });
	out.push(`${cells.join(",")} ${j}`);
	return out;
}

const before = trail.length;
const awaited = await viaAwait();
console.log(`${trail.slice(0, before).join(" | ")} | await: ${trail.slice(before).join(" | ")} | ${awaited.join("")}`);
