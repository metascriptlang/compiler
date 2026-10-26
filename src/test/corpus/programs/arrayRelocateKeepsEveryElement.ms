// @xfail(raiser): a struct argument read from an element changes when the std splice overwrites that slot, card .inbox/compiler/2026-10-26-a-struct-argument-read-from-an-element-changes-when-the-slot-is-overwritten
// @stdout: relocate all-ok
class Node {
	name: string;
	next: Node | null = null;
	constructor(name: string) { this.name = name; }
}

struct Cell { label: string; rank: int32; }

function letter(i: int32): string {
	return String.fromCharCode(97 + i);
}

function nodeRow(xs: Node[]): string {
	return xs.map((x: Node): string => x.name).join("");
}

function cellRow(xs: Cell[]): string {
	return xs.map((x: Cell): string => x.label + String(x.rank)).join(",");
}

function nodes(): string {
	const xs: Node[] = [];
	for (let i: int32 = 0; i < 9; i += 1) xs.push(new Node(letter(i)));
	for (let i = 0; i + 1 < xs.length; i += 1) xs[i].next = xs[i + 1];
	xs[xs.length - 1].next = xs[0];
	xs.splice(2, 2);
	xs.splice(-2, 1);
	xs.splice(-20, 1);
	xs.splice(20, 1);
	xs.splice(1, -3);
	const a = nodeRow(xs);
	xs.reverse();
	const first = xs.shift();
	xs.sort((p: Node, q: Node): number => p.name < q.name ? 1 : p.name > q.name ? -1 : 0);
	const z = new Node("z");
	xs.splice(-1, 1, z);
	xs.splice(-30, 0, new Node("y"));
	xs.splice(1, 99);
	return `${a} ${first.name} ${nodeRow(xs)}`;
}

function strings(): string {
	const xs: string[] = [];
	for (let i: int32 = 0; i < 7; i += 1) xs.push(letter(i).repeat(2));
	xs.splice(-3, 2);
	xs.splice(-9, 0, "zz");
	xs.reverse();
	const first = xs.shift();
	xs.sort((p: string, q: string): number => p < q ? -1 : p > q ? 1 : 0);
	xs.splice(-1, 1, "qq");
	return `${first} ${xs.join(",")}`;
}

function numbers(): string {
	const xs: number[] = [5, 1, 4, 2, 3, 9, 7];
	xs.splice(-2, 1);
	xs.splice(-1, 0, 8);
	xs.sort((p: number, q: number): number => p - q);
	xs.reverse();
	const first = xs.shift();
	return `${first} ${xs.join(",")}`;
}

function ints(): string {
	const xs: int32[] = [50, 10, 40, 20, 30, 90, 70];
	xs.splice(-3, 2);
	xs.splice(1, 1);
	xs.splice(-1, 0, 60);
	xs.reverse();
	const first = xs.shift();
	xs.sort((p: int32, q: int32): number => p - q);
	xs.splice(-9, 1, 15);
	const ys: int64[] = [3, 1, 2];
	ys.sort((p: int64, q: int64): number => Number(p - q));
	ys.reverse();
	ys.splice(1, 1, 7);
	return `${first} ${xs.join(",")} ${ys.join(",")}`;
}

function cells(): string {
	const xs: Cell[] = [];
	for (let i: int32 = 0; i < 8; i += 1) xs.push({ label: letter(i).repeat(3), rank: (i * 5) % 8 });
	xs.splice(-2, 1);
	xs.splice(0, 1);
	xs.reverse();
	const first = xs.shift();
	xs.sort((p: Cell, q: Cell): number => p.rank - q.rank);
	xs.splice(-2, 1, { label: "z".repeat(3), rank: 9 });
	xs.splice(1, 0, xs[xs.length - 1]);
	return `${first.label} ${cellRow(xs)}`;
}

function closures(): string {
	const fs: (() => string)[] = [];
	for (let i: int32 = 0; i < 4; i += 1) {
		const tag = letter(i);
		fs.push((): string => tag);
	}
	const extra = "q";
	fs.splice(-1, 1, (): string => extra);
	fs.splice(0, 2);
	fs.reverse();
	return fs.map((f: () => string): string => f()).join("");
}

function churn(): number {
	let total = 0;
	for (let round = 0; round < 30; round += 1) {
		const ns: Node[] = [];
		const cs: Cell[] = [];
		for (let i: int32 = 0; i < 16; i += 1) {
			ns.push(new Node(letter(i) + String(round)));
			cs.push({ label: letter(15 - i).repeat(4), rank: i });
		}
		ns.splice(round % 16, 3);
		cs.splice(-(round % 16), 2);
		ns.splice(round % 5, 1, new Node("n"));
		cs.splice(-(round % 7), 1, { label: "w".repeat(round % 3), rank: round });
		ns.reverse();
		cs.sort((p: Cell, q: Cell): number => q.rank - p.rank);
		ns.shift();
		cs.shift();
		total = total + ns.length + cs.length;
	}
	return total;
}

const got = [nodes(), strings(), numbers(), ints(), cells(), closures(), String(churn())].join(" | ");
console.log(got);
const expect = "befgi i y | gg aa,bb,cc,dd,qq | 8 7,5,4,3,2,1 | 70 15,40,50,60 3,7,1 | hhh fff1,ddd7,ccc2,eee4,zzz9,ddd7 | qc | 755";
console.log(got == expect ? "relocate all-ok" : "MISMATCH");
