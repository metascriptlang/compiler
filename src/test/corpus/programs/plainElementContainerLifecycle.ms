// @stdout: maps 1 7 9840 0 49 false true 19 7 | vecs 10 0 11 -1 3 1 0 5 1 9 a0 z 2 3 1 4
// @exit: 0
struct P { x: int32; y: int32 }
struct Pair<A, B> { a: A; b: B }
struct Holder { ps: Vec<P>; tag: int32 }
struct Nums { xs: Vec<int32> }
struct Named { name: string; n: int32 }

function maps(): string {
	const m = new Map<int32, int32>();
	for (let i: int32 = 0; i < 100; i++) m.set(i, i * 2);
	m.delete(10);
	m.delete(20);
	let sum: int32 = 0;
	for (const [k, v] of m) sum += v;
	m.clear();
	m.set(1, 7);
	const s = new Set<number>();
	for (let i: int32 = 0; i < 50; i++) s.add(i);
	s.delete(3);
	const s2 = new Set<number>();
	for (const v of s) s2.add(v);
	s.clear();
	const sm = new Map<string, int32>();
	for (let i: int32 = 0; i < 20; i++) sm.set("k" + i.toString(), i);
	sm.delete("k3");
	return `maps ${m.size} ${m.get(1)} ${sum} ${s.size} ${s2.size} ${s2.has(3)} ${s2.has(4)} ${sm.size} ${sm.get("k7")}`;
}

function vecs(): string {
	let a: Holder = { ps: [], tag: 1 };
	for (let i: int32 = 0; i < 10; i++) a.ps.push({ x: i, y: i * i });
	let b: Holder = { ps: [{ x: 100, y: 100 }], tag: 2 };
	b = a;
	a.ps[0] = { x: -1, y: -1 };
	a.ps.push({ x: 50, y: 50 });
	const copied = `${b.ps.length} ${b.ps[0].x} ${a.ps.length} ${a.ps[0].x}`;
	let shorter: Holder = { ps: [{ x: 1, y: 1 }, { x: 2, y: 2 }, { x: 3, y: 3 }], tag: 3 };
	b = shorter;
	shorter.ps[0] = { x: 7, y: 7 };
	const shrunk = `${b.ps.length} ${b.ps[0].x}`;
	b.ps = [];
	const cleared = `${b.ps.length}`;
	let pv: Vec<Pair<int32, int32>> = [];
	for (let i: int32 = 0; i < 5; i++) pv.push({ a: i, b: i });
	let pw = pv;
	pv[1] = { a: 9, b: 9 };
	const pairs = `${pw.length} ${pw[1].a} ${pv[1].a}`;
	let nv: Vec<Named> = [];
	for (let i: int32 = 0; i < 2; i++) nv.push({ name: "a" + i.toString(), n: i });
	let nw = nv;
	nv[0] = { name: "z", n: 9 };
	const named = `${nw[0].name} ${nv[0].name} ${nw.length}`;
	let n1: Nums = { xs: [1, 2, 3] };
	let n2: Nums = { xs: [4, 5, 6, 7] };
	n2 = n1;
	n1.xs.push(4);
	const nums = `${n2.xs.length} ${n2.xs[0]} ${n1.xs.length}`;
	return `vecs ${copied} ${shrunk} ${cleared} ${pairs} ${named} ${nums}`;
}

console.log(`${maps()} | ${vecs()}`);
