// @stdout: fields 2 1 | elements 4 3 | across 5 6 | structs b:1 a:2 | strings y x | numbers 9 8 | index once 1 | ref param 11 10 | generic 13 12 | locals 15 14
// @stdout: hashmap 300 sum 45150 after delete 100 sum 14950
// @stdout: hashset 300 sum 45150 after delete 100 sum 14950
// @stdout: map first 0,1,2 last 297,298,299 after delete 100 order 0,3,6 .. 291,294,297
// @stdout: set first 0,1,2 last 297,298,299 after delete 100 order 0,3,6 .. 291,294,297
// note: swap exchanges two places of one type, each evaluated once, so a field or element trades its value without being left empty; the hash tables grow and compact through it, keeping iteration order.

class Leaf {
	v: int32;
	constructor(v: int32) { this.v = v; }
}
class Holder {
	leaf: Leaf;
	constructor(v: int32) { this.leaf = new Leaf(v); }
}
struct Named { name: string; kids: Vec<int32>; leaf: Leaf; }
class Bag { item: Named; n: int32; constructor(name: string, n: int32) { this.item = { name, kids: [n], leaf: new Leaf(n) }; this.n = n; } }

let reads: int32 = 0;

function at(i: int32): int32 {
	reads = reads + 1;
	return i;
}

function viaRef(ref a: Leaf, ref b: Leaf): void {
	swap(a, b);
}

function exchange<T>(ref a: T, ref b: T): void {
	swap(a, b);
}

function places(): string {
	const h1 = new Holder(1);
	const h2 = new Holder(2);
	swap(h1.leaf, h2.leaf);
	const fields = `fields ${h1.leaf.v} ${h2.leaf.v}`;

	const xs: Leaf[] = [new Leaf(3), new Leaf(4)];
	swap(xs[0], xs[1]);
	const elements = `elements ${xs[0].v} ${xs[1].v}`;

	const h3 = new Holder(6);
	const ys: Leaf[] = [new Leaf(5)];
	swap(h3.leaf, ys[at(0)]);
	const across = `across ${h3.leaf.v} ${ys[0].v}`;

	const b1 = new Bag("a", 1);
	const b2 = new Bag("b", 2);
	swap(b1.item, b2.item);
	const structs = `structs ${b1.item.name}:${b2.item.kids[0]} ${b2.item.name}:${b1.item.leaf.v}`;

	const names: string[] = ["x" + String(reads), "y"];
	swap(names[0], names[1]);
	const strings = `strings ${names[0]} ${names[1].charAt(0)}`;

	const ns: int32[] = [8, 9];
	swap(ns[0], ns[1]);
	const numbers = `numbers ${ns[0]} ${ns[1]}`;

	reads = 0;
	const zs: Leaf[] = [new Leaf(7), new Leaf(8)];
	swap(zs[at(0)], h3.leaf);
	const once = `index once ${reads}`;

	const h4 = new Holder(10);
	const h5 = new Holder(11);
	viaRef(h4.leaf, h5.leaf);
	const viaRefs = `ref param ${h4.leaf.v} ${h5.leaf.v}`;

	const g: Leaf[] = [new Leaf(12), new Leaf(13)];
	exchange(g[0], g[1]);
	const generic = `generic ${g[0].v} ${g[1].v}`;

	let l1 = new Leaf(14);
	let l2 = new Leaf(15);
	swap(l1, l2);
	const locals = `locals ${l1.v} ${l2.v}`;

	return `${fields} | ${elements} | ${across} | ${structs} | ${strings} | ${numbers} | ${once} | ${viaRefs} | ${generic} | ${locals}`;
}

function hashMapGrowth(): string {
	const keys: Leaf[] = [];
	const m = new HashMap<Leaf, Leaf>();
	for (let i: int32 = 0; i < 300; i++) {
		const k = new Leaf(i + 1);
		keys.push(k);
		m.set(k, new Leaf(i + 1));
	}
	let sum: int32 = 0;
	for (const k of keys) sum = sum + m.get(k)!.v;
	const before = `hashmap ${m.size} sum ${sum}`;
	for (let i: int32 = 0; i < 300; i++) if (i % 3 != 0) m.delete(keys[i]);
	sum = 0;
	for (const k of keys) {
		const v = m.get(k);
		if (v != null) sum = sum + v.v;
	}
	return `${before} after delete ${m.size} sum ${sum}`;
}

function hashSetGrowth(): string {
	const keys: Leaf[] = [];
	const s = new HashSet<Leaf>();
	for (let i: int32 = 0; i < 300; i++) {
		const k = new Leaf(i + 1);
		keys.push(k);
		s.add(k);
	}
	let sum: int32 = 0;
	for (const k of keys) if (s.has(k)) sum = sum + k.v;
	const before = `hashset ${s.size} sum ${sum}`;
	for (let i: int32 = 0; i < 300; i++) if (i % 3 != 0) s.delete(keys[i]);
	sum = 0;
	for (const k of keys) if (s.has(k)) sum = sum + k.v;
	return `${before} after delete ${s.size} sum ${sum}`;
}

function edges(order: int32[]): string {
	const n = order.length;
	return `first ${order[0]},${order[1]},${order[2]} last ${order[n - 3]},${order[n - 2]},${order[n - 1]}`;
}

function mapOrder(): string {
	const keys: Leaf[] = [];
	const m = new Map<Leaf, Leaf>();
	for (let i: int32 = 0; i < 300; i++) {
		const k = new Leaf(i);
		keys.push(k);
		m.set(k, new Leaf(i));
	}
	const seen: int32[] = [];
	for (const [k, v] of m) seen.push(v.v);
	const before = `map ${edges(seen)}`;
	for (let i: int32 = 0; i < 300; i++) if (i % 3 != 0) m.delete(keys[i]);
	const after: int32[] = [];
	for (const [k, v] of m) after.push(k.v);
	return `${before} after delete ${m.size} order ${after[0]},${after[1]},${after[2]} .. ${after[after.length - 3]},${after[after.length - 2]},${after[after.length - 1]}`;
}

function setOrder(): string {
	const keys: Leaf[] = [];
	const s = new Set<Leaf>();
	for (let i: int32 = 0; i < 300; i++) {
		const k = new Leaf(i);
		keys.push(k);
		s.add(k);
	}
	const seen: int32[] = [];
	for (const k of s) seen.push(k.v);
	const before = `set ${edges(seen)}`;
	for (let i: int32 = 0; i < 300; i++) if (i % 3 != 0) s.delete(keys[i]);
	const after: int32[] = [];
	for (const k of s) after.push(k.v);
	return `${before} after delete ${s.size} order ${after[0]},${after[1]},${after[2]} .. ${after[after.length - 3]},${after[after.length - 2]},${after[after.length - 1]}`;
}

console.log(places());
console.log(hashMapGrowth());
console.log(hashSetGrowth());
console.log(mapOrder());
console.log(setOrder());
