// Owned<T> is an owning edge of a class reference: a cycle needs one edge that is not owned, any
// reference of the class enters an owned slot, and an object may sit in several owned slots.
// Runtime behaviour: corpus `ownedTreeDrop`, `ownedField*`, `ownedElementsMoveBetweenHolders`.

import { compileToC } from "../helpers";

function typeInfoOf(c: string, name: string): string {
	const named = name.endsWith("_") ? `.name = "${name}` : `.name = "${name}"`;
	for (const line of c.split("\n")) {
		if (line.contains(`msTypeInfo ${name}`) && line.contains(named)) return line;
	}
	return "";
}

function verdict(decls: string, name: string): string {
	const r = compileToC(decls + "\nconsole.log(\"ok\");\n");
	if (!r.ok) return r.error;
	const line = typeInfoOf(r.value, name);
	if (line == "") return `no TypeInfo for ${name}`;
	return line.contains(".isCyclic = MS_TRUE") ? "cyclic" : "acyclic";
}

function refused(src: string): string {
	const r = compileToC(src);
	return r.ok ? "compiled" : r.error;
}

test "a Vec of owned children is acyclic" {
	assert verdict("class N { kids: Vec<Owned<N>> = []; }\nconst n = new N();", "N") == "acyclic";
}

test "a Vec of plain children is cyclic" {
	assert verdict("class N { kids: Vec<N> = []; }\nconst n = new N();", "N") == "cyclic";
}

test "an array of owned children is acyclic, through nullable elements and nested arrays too" {
	assert verdict("class N { kids: Owned<N>[] = []; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("class N { kids: Array<Owned<N> | null> = []; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("class N { grid: Owned<N>[][] = []; }\nconst n = new N();", "N") == "acyclic";
	assert refused("class N { v: int32 = 0; }\ntype Kid = Owned<N>;\nfunction f(ks: Kid[]): int32 { return ks.length; }\nconsole.log(f([new N()]));\n") == "compiled";
}

test "an array of owned children beside a plain back edge is cyclic" {
	assert verdict("class N { kids: Owned<N>[] = []; up: N | null = null; }\nconst n = new N();", "N") == "cyclic";
}

test "an Owned<U> slot of a declared union keeps U's C type, so reading it as U converts nothing" {
	const src = "class N { v: int32 = 0; data: Owned<D> = { kind: 3 } as D; }\ntype A = { kind: 1; l: Owned<N> | null };\ntype B = { kind: 2; r: Owned<N> | null };\ntype C = { kind: 3 };\ntype D = A | B | C;\nfunction read(n: N): D { return n.data; }\nfunction share(to: N, from: N): void { to.data = from.data; }\nconst n = new N();\nconst m = new N();\nshare(m, n);\nconsole.log(read(m).kind);\n";
	const r = compileToC(src);
	assert r.ok, r.ok ? "" : r.error;
	assert !r.value.contains("msUnionConv_"), "Owned<D> and D share one C union, so a read of n.data copies it as it is";
}

test "a plain array of plain children is cyclic" {
	assert verdict("class N { kids: N[] = []; }\nconst n = new N();", "N") == "cyclic";
}

test "an owned link is acyclic" {
	assert verdict("class N { next: Owned<N> | null = null; }\nconst n = new N();", "N") == "acyclic";
}

test "an owned edge into a class with a plain edge back is cyclic" {
	const decls = "class A { b: Owned<B> | null = null; }\nclass B { a: A | null = null; }\nconst a = new A();\nconst b = new B();";
	assert verdict(decls, "A") == "cyclic";
	assert verdict(decls, "B") == "cyclic";
}

test "Owned of an alias that names its own holder keeps the owned edge" {
	assert verdict("type D = { l: Owned<N>, r: Owned<N> } | { x: int32 };\nclass N { data: Owned<D> = { x: 1 }; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("class N { data: Owned<D> = { x: 1 }; }\ntype D = { l: Owned<N>, r: Owned<N> } | { x: int32 };\nconst n = new N();", "N") == "acyclic";
	assert verdict("type D = { l: Owned<N> } | { x: int32 };\nclass N { data: Owned<D> | null = null; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("type P = N;\nclass N { next: Owned<P> | null = null; }\nconst n = new N();", "N") == "acyclic";
}

test "Owned of a union of records owns whichever record the slot holds" {
	assert verdict("class N { data: Owned<{ l: Owned<N>, r: Owned<N> } | { x: int32 }> = { x: 1 }; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("type D = Owned<{ l: Owned<N> }> | Owned<{ x: int32 }>;\nclass N { data: D = { x: 1 }; }\nconst n = new N();", "N") == "acyclic";
}

test "an Owned union slot reads as a plain union or member without a copy of the owner" {
	const decls = "type A = { l: Owned<N> };\ntype B = { x: int32 };\nclass N { k: int32 = 0; ab: Owned<A> | Owned<B> = { x: 1 }; }\nfunction arg(d: A | B): int32 { return \"x\" in d ? d.x : 0; }\n";
	const r = compileToC(decls + "function f(n: N): int32 { const d: B | A = n.ab; const e: A | B = n.ab; const a = n.ab as A; return arg(n.ab) + arg(d) + arg(e) + a.l.k; }\nconsole.log(f(new N()));\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "an owned value type and its plain twin share one C struct" {
	const decls = "type A = { l: Owned<N> };\ntype B = { x: int32 };\nclass N { k: int32 = 0; data: Owned<A> | Owned<B> | null = null; pair: [Owned<N> | null, int32] = [null, 0]; }\nclass H { d: A | B | null = null; pair: [N | null, int32] = [null, 0]; }\n";
	const r = compileToC(decls + "function f(n: N): int32 { const d: A | B | null = n.data; const p: [N | null, int32] = n.pair; return d == null ? p[1] : 1; }\nconsole.log(f(new N()), new H().pair[1]);\n");
	assert r.ok, r.ok ? "" : r.error;
	if (r.ok) assert !r.value.contains("OwnedRef"), "a struct name spells Owned";
}

test "a plain edge into a record that owns its holder is cyclic" {
	assert verdict("type D = { l: Owned<N> } | { x: int32 };\nclass N { data: D = { x: 1 }; }\nconst n = new N();", "N") == "cyclic";
}

test "Owned of a union with a member that is not a class is refused" {
	assert refused("class N { data: Owned<{ x: int32 } | string> = { x: 1 }; }\nconst n = new N();\n").contains("member 'string' is not a class");
	assert refused("type D = { x: int32 } | int32;\nclass N { data: Owned<D> = 1; }\nconst n = new N();\n").contains("is not a class");
}

test "owned edges through a generic class stay acyclic" {
	assert verdict("class Node<T> { v: T; kids: Vec<Owned<Node<T>>> = []; constructor(v: T) { this.v = v; } }\nconst n = new Node<int32>(1);", "Node_") == "acyclic";
}

const TREE = `class N { id: int32 = 0; kids: Vec<Owned<N>> = []; next: Owned<N> | null = null; }
function adopt(root: Owned<N>): void {
`;

test "an owned local pushed twice compiles" {
	assert refused(TREE + "const a: Owned<N> = new N();\nroot.kids.push(a);\nroot.kids.push(a);\n}\nadopt(new N());\n") == "compiled";
}

test "an owned field takes an element another owned slot holds" {
	const r = compileToC(TREE + "root.kids.push(new N());\nconst other: Owned<N> = new N();\nother.next = root.kids[0];\nconsole.log(root.kids[0].id);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "the last read of an owned local moves it" {
	const r = compileToC(TREE + "const a: Owned<N> = new N();\nroot.kids.push(a);\nconsole.log(root.kids.length);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "an owned value reads as a plain reference without a copy of the owner" {
	const r = compileToC(TREE + "const a: Owned<N> = new N();\nconst p: N = a;\nconsole.log(a.id, p.id);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a plain reference enters an owned element slot and stays readable" {
	const r = compileToC(TREE + "let p: N = new N();\nroot.kids.push(p);\nconsole.log(p.id);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a plain argument passes to an owned parameter" {
	assert refused("class N { id: int32 = 0; }\nfunction take(x: Owned<N>): void { console.log(x.id); }\ntake(new N());\nlet p: N = new N();\ntake(p);\nconsole.log(p.id);\n") == "compiled";
}

test "a fresh value and null become owned" {
	const r = compileToC("class L { next: Owned<L> | null = null; }\nconst l: Owned<L> = new L();\nl.next = new L();\nl.next = null;\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a Vec holding owned edges is copied while it is still read" {
	assert refused(TREE + "const other: Owned<N> = new N();\nother.kids = root.kids;\nconsole.log(root.kids.length);\n}\nadopt(new N());\n") == "compiled";
}

test "a struct holding an owned field is copied while it is still read" {
	const message = refused("class N { id: int32 = 0; }\nstruct S { a: Owned<N>; n: int32; }\nfunction f(): void {\n\tconst s: S = { a: new N(), n: 1 };\n\tlet t: S = { a: new N(), n: 2 };\n\tt = s;\n\tconsole.log(s.n, t.n);\n}\nf();\n");
	assert message == "compiled", message;
}

const HELD = "class N { id: int32 = 0; }\nstruct Plain { n: Owned<N>; }\nstruct Gen<T> { n: Owned<N>; tag: T; }\n";

test "a generic struct instance holding an owned field is copied while it is still read" {
	const message = refused(HELD + "function f(): void {\n\tconst a: Gen<int32> = { n: new N(), tag: 0 };\n\tconst b = a;\n\tconsole.log(a.n.id, b.n.id);\n}\nf();\n");
	assert message == "compiled", message;
}

test "an alias of a struct holding an owned field is copied while it is still read" {
	const plain = refused(HELD + "type W = Plain;\nfunction f(): void {\n\tconst a: W = { n: new N() };\n\tconst b = a;\n\tconsole.log(a.n.id, b.n.id);\n}\nf();\n");
	assert plain == "compiled", plain;
	const generic = refused(HELD + "type G = Gen<int32>;\nfunction f(): void {\n\tconst a: G = { n: new N(), tag: 0 };\n\tconst b = a;\n\tconsole.log(a.n.id, b.n.id);\n}\nf();\n");
	assert generic == "compiled", generic;
}

test "a generic class holding an owned field is copied as a shared reference" {
	assert refused("class N { id: int32 = 0; }\nclass Box<T> { n: Owned<N> = new N(); tag: T;\n\tconstructor(tag: T) { this.tag = tag; }\n}\nfunction f(): void {\n\tconst a = new Box<int32>(0);\n\tconst b = a;\n\tconsole.log(a.n.id, b.n.id);\n}\nf();\n") == "compiled";
}

test "Owned takes a class" {
	assert refused("const v: Owned<string> = \"x\";\nconsole.log(v);\n").contains("Owned<T> takes a class type");
	assert refused("struct S { a: int32 }\nconst v: Owned<S> = { a: 1 };\nconsole.log(v.a);\n").contains("Owned<T> takes a class type");
}

test "an Owned annotation error on a lambda parameter is reported once" {
	const forms = [
		"const f = (x: Owned<int32>): void => { console.log(\"a\"); };\n",
		"const f = function (x: Owned<int32>): void { console.log(\"a\"); };\n",
		"function run(): void {\n\tconst g = (x: Owned<int32>): void => { console.log(\"a\"); };\n\tg;\n}\nrun();\n",
		"function run(): void {\n\tfunction g(x: Owned<int32>): void { console.log(\"a\"); }\n\tg;\n}\nrun();\n",
	];
	for (const form of forms) {
		const message = refused(form);
		assert message.split("Owned<T> takes a class type").length == 2, form + message;
	}
}

test "a const bound to a fresh value enters an owned slot at its last read" {
	const r = compileToC(TREE + "const b = new N();\nroot.kids.push(b);\nconsole.log(root.kids.length);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a const pushed twice compiles" {
	assert refused(TREE + "const b = new N();\nroot.kids.push(b);\nroot.kids.push(b);\n}\nadopt(new N());\n") == "compiled";
}

test "a const stays readable after it enters an owned slot" {
	assert refused(TREE + "const b = new N();\nroot.kids.push(b);\nconsole.log(b.id);\n}\nadopt(new N());\n") == "compiled";
}

test "a let bound to a fresh value enters an owned slot" {
	assert refused(TREE + "let b = new N();\nroot.kids.push(b);\n}\nadopt(new N());\n") == "compiled";
}

test "a const bound to a call result enters an owned slot" {
	assert refused("class N { id: int32 = 0; kids: Vec<Owned<N>> = []; }\nfunction make(): N { return new N(); }\nfunction f(root: N): void {\n\tconst b = make();\n\troot.kids.push(b);\n}\nf(new N());\n") == "compiled";
}

const TOP = "class N { id: int32 = 0; kids: Vec<Owned<N>> = []; }\nconst root = new N();\nroot.kids.push(new N());\n";

test "a module-level for-of over owned elements lends each element" {
	const r = compileToC(TOP + "let total = 0;\nfor (const k of root.kids) total += k.id;\nconsole.log(total);\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a module-level for-of whose body removes elements holds each element by a count" {
	const r = compileToC(TOP + "for (const k of root.kids) { root.kids.pop(); console.log(k.id); }\n");
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.contains("msIncref(dollarborrow_"), r.value;
}

test "a value popped from an owned Vec is a plain local" {
	assert refused(TOP + "const other = new N();\nconst moved = root.kids.pop()!;\nother.kids.push(moved);\nconsole.log(moved.id);\n") == "compiled";
}

const CAST = "class N { id: int32 = 0; kids: Vec<Owned<N>> = []; }\nconst a = new N();\nconst shared: N[] = [new N()];\n";

test "a cast of a shared reference into an owning edge compiles" {
	assert refused(CAST + "a.kids.push(shared[0] as Owned<N>);\n") == "compiled";
}

test "a cast of a fresh value into an owning edge is accepted" {
	const r = compileToC(CAST + "a.kids.push(new N() as Owned<N>);\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a fresh object literal cast to its plain union type enters an owned slot" {
	const r = compileToC("type D = { x: int32 } | { y: string };\nclass N { data: Owned<D> = { x: 0 }; }\nconst n = new N();\nn.data = { y: \"a\" } as D;\nconsole.log(\"y\" in n.data);\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a cast of a shared value into an owned union slot compiles" {
	assert refused("type D = { x: int32 } | { y: string };\nclass N { data: Owned<D> = { x: 0 }; }\nconst n = new N();\nconst shared: D[] = [{ x: 1 }];\nn.data = shared[0] as D;\n") == "compiled";
}

test "a cast through unknown into an owning edge compiles" {
	assert refused(CAST + "a.kids.push((shared[0] as unknown) as Owned<N>);\n") == "compiled";
}

test "an owned value cast to Owned passes the checker" {
	const message = refused(CAST + "function same(o: Owned<N>): Owned<N> { return o as Owned<N>; }\n");
	assert !message.contains("cannot cast"), message;
}

const REFILL = `class N { id: int32 = 0; kids: Vec<Owned<N>> = []; }
class P { head: Owned<N>; constructor(sink head: Owned<N>) { this.head = move head; } }
function rw(n: Owned<N>): Owned<N> { return move n; }
function rw2(n: Owned<N>, other: N): Owned<N> { return move n; }
`;

test "an owned element moved out and put back by the same assignment is accepted" {
	const r = compileToC(REFILL + "function f(n: Owned<N>): Owned<N> {\nfor (let i = 0; i < n.kids.length; i++) n.kids[i] = rw(move n.kids[i]);\nreturn move n;\n}\nf(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "an owned field of a ref parameter moved out and put back by the same assignment is accepted" {
	const r = compileToC(REFILL + "function f(ref p: P): void { p.head = rw(move p.head); }\nlet p = new P(new N());\nf(p);\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "an owned slot moved out by a plain parameter's path is refused" {
	const message = refused(REFILL + "function f(n: N): void { n.kids[0] = rw(move n.kids[0]); }\nf(new N());\n");
	assert message.contains("cannot move 'n.kids"), message;
}

test "an owned slot whose holder is read before the refill is refused" {
	const message = refused(REFILL + "function f(n: Owned<N>): Owned<N> { n.kids[0] = rw2(move n.kids[0], n); return move n; }\nf(new N());\n");
	assert message.contains("cannot use 'n': 'n.kids[…]' was moved out"), message;
}

test "an owned slot whose holder is read through an alias before the refill is refused" {
	const message = refused(REFILL + "function f(n: Owned<N>): Owned<N> { const k: N = n; n.kids[0] = rw2(move n.kids[0], k); return move n; }\nf(new N());\n");
	assert message.contains("cannot use 'k': 'n.kids[…]' was moved out"), message;
}

test "an owned slot put back into another place is refused" {
	const message = refused(REFILL + "function f(n: Owned<N>): Owned<N> { n.kids[0] = rw(move n.kids[1]); return move n; }\nf(new N());\n");
	assert message.contains("'n.kids[…]' was moved out"), message;
}

test "an owned slot whose index is written before the refill is refused" {
	const message = refused(REFILL + "function g(a: Owned<N>, i: int32): Owned<N> { return move a; }\nfunction f(n: Owned<N>): Owned<N> { let i = 0; n.kids[i] = g(move n.kids[i], i++); return move n; }\nf(new N());\n");
	assert message.contains("cannot write 'i': 'n.kids[…]' was moved out"), message;
	const between = refused(REFILL + "function f(n: Owned<N>): Owned<N> { let i = 0; const x = move n.kids[i]; i = 1; n.kids[i] = x; return move n; }\nf(new N());\n");
	assert between.contains("cannot write 'i'"), between;
}

test "an index written after its slot is put back is accepted" {
	const r = compileToC(REFILL + "function f(n: Owned<N>): Owned<N> { let i = 0; const x = move n.kids[i]; n.kids[i] = x; i = 1; n.kids[i] = rw(move n.kids[i]); return move n; }\nf(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "an owned slot moved out by one statement and put back by another is accepted" {
	const r = compileToC(REFILL + "function f(n: Owned<N>): Owned<N> { const x = move n.kids[0]; n.kids[0] = x; return move n; }\nf(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "an owned slot moved inside a closure of the refill is refused" {
	const message = refused(REFILL + "function f(n: Owned<N>): Owned<N> { n.kids[0] = rw((() => move n.kids[0])()); return move n; }\nf(new N());\n");
	assert message.contains("cannot move 'n.kids"), message;
}

test "an owned nullable element moved out by one statement is emptied" {
	const r = compileToC("class N { id: int32 = 0; kids: Vec<Owned<N> | null> = []; }\nfunction f(n: Owned<N>): Owned<N> {\nconst k = move n.kids[0];\nn.kids[0] = k;\nreturn move n;\n}\nf(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

const BIN = `class T { v: int32 = 0; kids: Vec<Owned<T>> = []; constructor(v: int32) { this.v = v; } }
class Bin { op: string = "+"; left: Owned<T>; right: Owned<T>; constructor(sink l: Owned<T>, sink r: Owned<T>) { this.left = move l; this.right = move r; } }
function use(b: Bin): int32 { return b.left.v; }
function mk(): Owned<Bin> { const b: Owned<Bin> = new Bin(new T(1), new T(2)); return move b; }
`;

test "a moved field read before it is put back is refused" {
	const message = refused(BIN + "function f(b: Owned<Bin>): Owned<Bin> { const l = move b.left; console.log(b.left.v, l.v); return move b; }\nf(mk());\n");
	assert message.contains("cannot use 'b.left.v': 'b.left' was moved out of it"), message;
}

test "a holder of a moved field passed to a call before the refill is refused" {
	const message = refused(BIN + "function f(b: Owned<Bin>): Owned<Bin> { const l = move b.left; console.log(use(b), l.v); b.left = move l; return move b; }\nf(mk());\n");
	assert message.contains("cannot use 'b': 'b.left' was moved out"), message;
}

test "a second element moved while the first is out is refused" {
	const message = refused(BIN + "function f(n: Owned<T>): Owned<T> { const a = move n.kids[0]; const b = move n.kids[1]; n.kids[0] = move a; n.kids[1] = move b; return move n; }\nf(new T(0));\n");
	assert message.contains("cannot use 'n.kids[…]': 'n.kids[…]' was moved out"), message;
}

test "an element moved again on the loop's next turn without a refill is refused" {
	const message = refused(BIN + "function f(n: Owned<T>): int32 { let s = 0; for (let i = 0; i < 2; i++) { const a = move n.kids[0]; s += a.v; } return s; }\nf(new T(0));\n");
	assert message.contains("'n.kids[…]' was moved out"), message;
}

test "a field put back on one branch only and read after the join is refused" {
	const message = refused(BIN + "function f(b: Owned<Bin>, flip: boolean): Owned<Bin> { const l = move b.left; if (flip) b.left = move l; console.log(b.left.v); return move b; }\nf(mk(), true);\n");
	assert message.contains("cannot use 'b.left.v': 'b.left' was moved out of it"), message;
}

test "a local alias of the holder read before the refill is refused" {
	const message = refused(BIN + "function f(b: Owned<Bin>): Owned<Bin> { const alias: Bin = b; const l = move b.left; console.log(alias.left.v, l.v); b.left = move l; return move b; }\nf(mk());\n");
	assert message.contains("cannot use 'alias.left.v'"), message;
}

test "a holder returned with a field still moved out is refused" {
	const message = refused(BIN + "function f(b: Owned<Bin>): Owned<Bin> { const l = move b.left; return move b; }\nf(mk());\n");
	assert message.contains("cannot use 'b': 'b.left' was moved out"), message;
}

const KIDS = "class K { v: int32 = 0; constructor(v: int32) { this.v = v; } }\nfunction mk(v: int32): Owned<K> { return new K(v); }\nconst kids: Vec<Owned<K>> = [mk(1), mk(2)];\n";

test "a bare type parameter lends an owned element to a callback" {
	const r = compileToC(KIDS + "console.log(kids.some((k) => k.v > 1), kids.every((k: K): boolean => k.v > 0), kids.findIndex((k) => k.v == 2));\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a callback that owns its element is refused where a bare type parameter lends it" {
	const message = refused(KIDS + "console.log(kids.some((k: Owned<K>): boolean => k.v > 1));\n");
	assert message.contains("takes 'k' as its owner, but the expected '(x: K, i: number) => boolean' passes it lent"), message;
}

test "a generic body stores a plain parameter into an owned Vec" {
	assert refused(KIDS + "function hold<T>(ref xs: Vec<T>, x: T): void { xs.push(x); }\nlet more: Vec<Owned<K>> = [];\nhold(more, mk(3));\nconst k = new K(4);\nhold(more, k);\nconsole.log(more.length, k.v);\n") == "compiled";
}

test "a sink type parameter takes an owned argument" {
	const r = compileToC(KIDS + "function hold<T>(ref xs: Vec<T>, sink x: T): void { xs.push(move x); }\nlet more: Vec<Owned<K>> = [];\nhold(more, mk(3));\nconsole.log(more.length);\n");
	assert r.ok, r.ok ? "" : r.error;
}
