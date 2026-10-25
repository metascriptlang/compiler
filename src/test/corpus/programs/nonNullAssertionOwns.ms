// @stdout: binding=7 argument=7 global=2,7,8 names=ab,cd interface=7 loop=21

class Node { left: Node | null = null; k: number = 0; }
class Holder { a: Node | null = null; }
interface Item { k: number; }
class ItemHolder { item: Item | null = null; }

let ints: int32[] | null = null;
let names: string[] | null = null;

function clearLeft(n: Node): void { n.left = null; }

function refill(n: Node): void {
	const z = new Node();
	z.k = 100;
	n.left = z;
}

function sevenLeft(): Node {
	const n = new Node();
	const child = new Node();
	child.k = 7;
	n.left = child;
	return n;
}

function binding(n: Node): number {
	const d = n.left!;
	clearLeft(n);
	refill(n);
	return d.k;
}

function sumWith(a: Node, b: number): number { return a.k + b; }

function bump(h: Holder): number {
	h.a = null;
	const z = new Node();
	z.k = 100;
	h.a = z;
	return 0;
}

function argument(h: Holder): number { return sumWith(h.a!, bump(h)); }

function swapInts(o: int32[] | null): int32[] {
	const c = ints!;
	ints = o;
	ints = [100, 100, 100];
	return c;
}

function swapNames(o: string[] | null): string[] {
	const c = names!;
	names = o;
	names = ["zzzz", "zzzz", "zzzz"];
	return c;
}

function interfaceField(h: ItemHolder): number {
	const it = h.item!;
	h.item = null;
	const z: Item = { k: 100 };
	h.item = z;
	return it.k;
}

function inLoop(n: Node): number {
	const d = n.left!;
	let sum: number = 0;
	for (let i = 0; i < 3; i++) {
		if (i == 1) {
			clearLeft(n);
			refill(n);
		}
		sum += d.k;
	}
	return sum;
}

function sevenHolder(): Holder {
	const h = new Holder();
	const a = new Node();
	a.k = 7;
	h.a = a;
	return h;
}

function sevenItem(): ItemHolder {
	const h = new ItemHolder();
	const it: Item = { k: 7 };
	h.item = it;
	return h;
}

function report(): string {
	ints = [7, 8];
	const gotInts = swapInts(null);
	ints = null;
	names = ["ab", "cd"];
	const gotNames = swapNames(null);
	names = null;
	return `binding=${binding(sevenLeft())} argument=${argument(sevenHolder())} global=${gotInts.length},${gotInts[0]},${gotInts[1]} names=${gotNames[0]},${gotNames[1]} interface=${interfaceField(sevenItem())} loop=${inLoop(sevenLeft())}`;
}

console.log(report());
