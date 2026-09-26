// nim-guard: under ORC a cycle between instances of one generic type, or of two
// generics that name each other, is collected, and a field read through such a
// link has the instance's type.
//
// Nim semtypinst.nim:469-474 handleGenericInvocation caches the instance
// (cacheTypeInst :60) before it fills the body, so `Box[T]` inside Box's own
// body resolves to the instance being built; types.nim:386 canFormAcycleAux
// skips an instance to its own body and marks that body by its id. NIM-REF
// CK-44 and AN-20 (SAME). Proven red on main c36ed0ab: the reads through a
// link fail the C build, and without them the cycles leak under orc (TOTAL
// alloc=1404 destroy=0).
//
// RED MEANS a recursive generic instance got the generic body instead of its
// own, or the cycle walk keyed an instance body by the generic's bare name; run
// /trace-nim on substituteAllParamsWalk (checker/types.ms) and cfaAux
// (transform/cycles.ms) for the named instance.
//
// GUARD-BALANCE-ORC TOTAL
// GUARD-JS

class Box<T> {
	val: T;
	other: Box<T> | null;
	peers: Box<T>[];
	constructor(v: T) { this.val = v; this.other = null; this.peers = []; }
}

class Pair<A, B> {
	a: A;
	next: Pair<B, A> | null;
	constructor(a: A) { this.a = a; this.next = null; }
}

class GA<T> {
	v: T;
	b: GB<T> | null;
	constructor(v: T) { this.v = v; this.b = null; }
}

class GB<T> {
	v: T;
	a: GA<T> | null;
	constructor(v: T) { this.v = v; this.a = null; }
}

interface INode<T> {
	val: T;
	next: INode<T> | null;
}

function viaNullable(i: int32): int32 {
	const a = new Box<int32>(i);
	const b = new Box<int32>(i + 1);
	a.other = b;
	b.other = a;
	return a.other!.other!.val;
}

function viaArray(i: int32): int32 {
	const a = new Box<string>("a" + i.toString());
	const b = new Box<string>("b" + i.toString());
	a.peers.push(b);
	b.peers.push(a);
	return a.peers[0].peers[0].val.length as int32;
}

function viaSwapped(i: int32): int32 {
	const p = new Pair<int32, string>(i);
	const q = new Pair<string, int32>("q" + i.toString());
	p.next = q;
	q.next = p;
	return p.next!.next!.a;
}

function viaTwoGenerics(i: int32): int32 {
	const x = new GA<string>("x" + i.toString());
	const y = new GB<string>("y" + i.toString());
	x.b = y;
	y.a = x;
	return x.b!.a!.v.length as int32;
}

function viaInterface(i: int32): int32 {
	const a: INode<string> = { val: "a" + i.toString(), next: null };
	const b: INode<string> = { val: "b" + i.toString(), next: null };
	a.next = b;
	b.next = a;
	return a.next!.next!.val.length as int32;
}

function main(): void {
	let s: int32 = 0;
	for (let i: int32 = 0; i < 100; i += 1) {
		s = s + viaNullable(i) + viaArray(i) + viaSwapped(i) + viaTwoGenerics(i) + viaInterface(i);
	}
	console.log(s);
	const a = new Box<string>("a");
	const b = new Box<string>("b");
	a.other = b;
	b.other = a;
	if (a.other!.other!.val == "a") console.log("GUARD-OK");
}
main();
