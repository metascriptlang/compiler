// bug335 — a generic class whose instance links to itself was judged acyclic
//
// Symptom:    `class Box<T> { other: Box<T> | null }` with a.other = b, b.other = a:
//             Box<int32> had no =trace, its TypeInfo no traceFn, and its field
//             release used msDecref, so ORC never saw the cycle (alloc=2 destroy=0).
//             A read through the link, `a.other!.other!.val`, was typed `T` and
//             printed "<T>" on C and JS.
//
// Root cause: instantiating Box<int32> cut the recursive `Box<T>` inside its own body
//             at the active path and kept the generic body there, so the link's
//             instance still had fields of type `T`. The cycle walk, asked from that
//             link first, found no way back to Box<int32> and cached the instance
//             name as acyclic.
//
// Fix:        the recursive link stays a lazy instance whose body is filled on first
//             use, as the reference caches an instance before it fills the body
//             (handleGenericInvocation, cacheTypeInst); the cycle walk fills a lazy
//             instance before walking it and keys an instance body by the instance,
//             not by the generic's bare name (canFormAcycleAux).

import { compileToC, compileToJS } from "../helpers";

test "bug335: a nullable field back to its own generic instance is traced" {
	const src = `
class Box<T> {
	val: T;
	other: Box<T> | null;
	constructor(v: T) { this.val = v; this.other = null; }
}
const a = new Box<int32>(1 as int32);
const b = new Box<int32>(2 as int32);
a.other = b;
b.other = a;
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("msOrcTraceRef(&((*self).other), callback);");
		assert c.value.contains("msDecrefCyclic((*self).other);");
	}
}

test "bug335: an array field of its own generic instance is traced" {
	const src = `
class Box<T> {
	val: T;
	peers: Box<T>[];
	constructor(v: T) { this.val = v; this.peers = []; }
}
const a = new Box<string>("a");
const b = new Box<string>("b");
a.peers.push(b);
b.peers.push(a);
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("msOrcTraceRef(&((*self).peers), callback);");
	}
}

test "bug335: a field to the swapped instance of its own generic is traced" {
	const src = `
class Pair<A, B> {
	a: A;
	next: Pair<B, A> | null;
	constructor(a: A) { this.a = a; this.next = null; }
}
const p = new Pair<int32, string>(1 as int32);
const q = new Pair<string, int32>("q");
p.next = q;
q.next = p;
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("msOrcTraceRef(&((*self).next), callback);");
	}
}

test "bug335: two generic classes linking each other's instances are traced" {
	const src = `
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
const x = new GA<int32>(1 as int32);
const y = new GB<int32>(2 as int32);
x.b = y;
y.a = x;
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("msOrcTraceRef(&((*self).b), callback);");
		assert c.value.contains("msOrcTraceRef(&((*self).a), callback);");
	}
}

test "bug335: a generic interface linking to its own instance is traced" {
	const src = `
interface INode<T> {
	val: T;
	next: INode<T> | null;
}
const a: INode<string> = { val: "a", next: null };
const b: INode<string> = { val: "b", next: null };
a.next = b;
b.next = a;
`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains("msOrcTraceRef(&((*self).next), callback);");
		assert c.value.contains("msDecrefCyclic((*self).next);");
	}
}

const readThroughLink = `
class Box<T> {
	val: T;
	other: Box<T> | null;
	constructor(v: T) { this.val = v; this.other = null; }
}
function show(a: Box<string>): void {
	console.log(a.other!.other!.val);
}
const a = new Box<string>("a");
const b = new Box<string>("b");
a.other = b;
b.other = a;
show(a);
`;

test "bug335: a field read through the link to its own instance keeps the instance type on C" {
	const c = compileToC(readThroughLink);
	assert c.ok;
	if (c.ok) {
		assert c.value.contains(".other).other).val);");
		assert !c.value.contains("\"<T>\"");
	}
}

test "bug335: a field read through the link to its own instance keeps the instance type on JS" {
	const j = compileToJS(readThroughLink);
	assert j.ok;
	if (j.ok) {
		assert j.value.contains(".other.other.val);");
		assert !j.value.contains("\"<T>\"");
	}
}
