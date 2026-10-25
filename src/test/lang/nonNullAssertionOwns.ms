// Language tests: `x!` is a type assertion only, so a binding or an argument made from it keeps
// its value alive exactly as the same read without `!` does, while the source is cleared and its
// memory reused.

class BangNode { left: BangNode | null = null; k: number = 0; }
class BangHolder { a: BangNode | null = null; }
interface BangItem { k: number; }
class BangItemHolder { item: BangItem | null = null; }

let bangInts: int32[] | null = null;
let bangNames: string[] | null = null;

function clearLeft(n: BangNode): void { n.left = null; }

function refill(n: BangNode): void {
	const z = new BangNode();
	z.k = 100;
	n.left = z;
}

function bangBinding(n: BangNode): number {
	const d = n.left!;
	clearLeft(n);
	refill(n);
	return d.k;
}

function plainBinding(n: BangNode): number {
	const d = n.left;
	clearLeft(n);
	refill(n);
	return d == null ? -1 : d.k;
}

function sumWith(a: BangNode, b: number): number { return a.k + b; }

function bump(h: BangHolder): number {
	h.a = null;
	const z = new BangNode();
	z.k = 100;
	h.a = z;
	return 0;
}

function bangArgument(h: BangHolder): number { return sumWith(h.a!, bump(h)); }

function swapInts(o: int32[] | null): int32[] {
	const c = bangInts!;
	bangInts = o;
	bangInts = [100, 100, 100];
	return c;
}

function swapNames(o: string[] | null): string[] {
	const c = bangNames!;
	bangNames = o;
	bangNames = ["zzzz", "zzzz", "zzzz"];
	return c;
}

function bangInterfaceField(h: BangItemHolder): number {
	const it = h.item!;
	h.item = null;
	const z: BangItem = { k: 100 };
	h.item = z;
	return it.k;
}

function bangInLoop(n: BangNode): number {
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

function sevenLeft(): BangNode {
	const n = new BangNode();
	const child = new BangNode();
	child.k = 7;
	n.left = child;
	return n;
}

function sevenHolder(): BangHolder {
	const h = new BangHolder();
	const a = new BangNode();
	a.k = 7;
	h.a = a;
	return h;
}

function sevenItem(): BangItemHolder {
	const h = new BangItemHolder();
	const it: BangItem = { k: 7 };
	h.item = it;
	return h;
}

test "a binding of a non-null asserted field keeps the old child after the field is cleared" {
	assert bangBinding(sevenLeft()) == 7;
}

test "a binding of the same field without the assertion keeps the old child too" {
	assert plainBinding(sevenLeft()) == 7;
}

test "a non-null asserted argument keeps its value while a later argument clears the field" {
	assert bangArgument(sevenHolder()) == 7;
}

test "a binding of a non-null asserted global array keeps it after the global is reassigned" {
	bangInts = [7, 8];
	const got = swapInts(null);
	bangInts = null;
	assert got.length == 2;
	assert got[0] == 7;
	assert got[1] == 8;
}

test "a binding of a non-null asserted global string array keeps it after the global is reassigned" {
	bangNames = ["ab", "cd"];
	const got = swapNames(null);
	bangNames = null;
	assert got.length == 2;
	assert got[0] == "ab";
	assert got[1] == "cd";
}

test "a binding of a non-null asserted interface field keeps the old value after the field is replaced" {
	assert bangInterfaceField(sevenItem()) == 7;
}

test "a non-null asserted binding read in a loop body keeps the old child after the field is cleared" {
	assert bangInLoop(sevenLeft()) == 21;
}
