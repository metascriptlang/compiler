// Owned<T> is the unique owning edge of a class reference: a cycle needs one edge that is not
// owned, a copy of an owned location is refused unless it is the last read, and a plain
// reference becomes owned only when it is fresh. Runtime behaviour: corpus `ownedTreeDrop`.

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

test "an owned child behind a shared array is cyclic" {
	assert verdict("class N { kids: Owned<N>[] = []; }\nconst n = new N();", "N") == "cyclic";
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

test "owned edges through a generic class stay acyclic" {
	assert verdict("class Node<T> { v: T; kids: Vec<Owned<Node<T>>> = []; constructor(v: T) { this.v = v; } }\nconst n = new Node<int32>(1);", "Node_") == "acyclic";
}

const TREE = `class N { id: int32 = 0; kids: Vec<Owned<N>> = []; next: Owned<N> | null = null; }
function adopt(root: Owned<N>): void {
`;

test "copying an owned local into a second owner is refused" {
	const message = refused(TREE + "const a: Owned<N> = new N();\nroot.kids.push(a);\nroot.kids.push(a);\n}\n");
	assert message.contains("cannot copy 'a'"), message;
}

test "copying an owned field into a second owner is refused" {
	const message = refused(TREE + "root.kids.push(new N());\nconst other: Owned<N> = new N();\nother.next = root.kids[0];\nconsole.log(root.kids[0].id);\n}\n");
	assert message.contains("cannot copy 'root.kids[0]'"), message;
}

test "the last read of an owned local moves it" {
	const r = compileToC(TREE + "const a: Owned<N> = new N();\nroot.kids.push(a);\nconsole.log(root.kids.length);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "an owned value reads as a plain reference without a copy of the owner" {
	const r = compileToC(TREE + "const a: Owned<N> = new N();\nconst p: N = a;\nconsole.log(a.id, p.id);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a plain reference does not become owned" {
	const message = refused(TREE + "let p: N = new N();\nroot.kids.push(p);\n}\n");
	assert message.contains("Type 'N' is not assignable to type 'Owned<N>'"), message;
}

test "a plain argument does not become an owned parameter" {
	const message = refused("class N { id: int32 = 0; }\nfunction take(x: Owned<N>): void { console.log(x.id); }\ntake(new N());\nlet p: N = new N();\ntake(p);\n");
	assert message.contains("Type 'N' is not assignable to type 'Owned<N>'"), message;
}

test "a fresh value and null become owned" {
	const r = compileToC("class L { next: Owned<L> | null = null; }\nconst l: Owned<L> = new L();\nl.next = new L();\nl.next = null;\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a Vec holding an owned edge is copied only at its last read" {
	const message = refused(TREE + "const other: Owned<N> = new N();\nother.kids = root.kids;\nconsole.log(root.kids.length);\n}\n");
	assert message.contains("cannot copy 'root.kids'"), message;
}

test "a struct holding an owned field is move-only" {
	const message = refused("class N { id: int32 = 0; }\nstruct S { a: Owned<N>; n: int32; }\nfunction f(): void {\n\tconst s: S = { a: new N(), n: 1 };\n\tlet t: S = { a: new N(), n: 2 };\n\tt = s;\n\tconsole.log(s.n, t.n);\n}\nf();\n");
	assert message.contains("cannot copy 's'"), message;
}

test "Owned takes a class" {
	assert refused("const v: Owned<string> = \"x\";\nconsole.log(v);\n").contains("Owned<T> takes a class type");
	assert refused("struct S { a: int32 }\nconst v: Owned<S> = { a: 1 };\nconsole.log(v.a);\n").contains("Owned<T> takes a class type");
}

test "a const bound to a fresh value enters an owned slot at its last read" {
	const r = compileToC(TREE + "const b = new N();\nroot.kids.push(b);\nconsole.log(root.kids.length);\n}\nadopt(new N());\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a fresh const read again after entering an owned slot is a refused copy" {
	const message = refused(TREE + "const b = new N();\nroot.kids.push(b);\nroot.kids.push(b);\n}\n");
	assert message.contains("cannot copy 'b'"), message;
}

test "a fresh const that is read after entering an owned slot is refused" {
	const message = refused(TREE + "const b = new N();\nroot.kids.push(b);\nconsole.log(b.id);\n}\n");
	assert message.contains("cannot copy 'b'"), message;
}

test "a let bound to a fresh value does not enter an owned slot" {
	const message = refused(TREE + "let b = new N();\nroot.kids.push(b);\n}\n");
	assert message.contains("Type 'N' is not assignable to type 'Owned<N>'"), message;
}

test "a const bound to a plain reference does not enter an owned slot" {
	const message = refused("class N { id: int32 = 0; kids: Vec<Owned<N>> = []; }\nfunction make(): N { return new N(); }\nfunction f(root: N): void {\n\tconst b = make();\n\troot.kids.push(b);\n}\n");
	assert message.contains("Type 'N' is not assignable to type 'Owned<N>'"), message;
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

test "a module-level owned local is never a last read" {
	const message = refused(TOP + "const other = new N();\nconst moved = root.kids.pop()!;\nother.kids.push(moved);\n");
	assert message.contains("cannot copy 'moved'") && message.contains("'move'"), message;
}

const CAST = "class N { id: int32 = 0; kids: Vec<Owned<N>> = []; }\nconst a = new N();\nconst shared: N[] = [new N()];\n";

test "a cast of a shared reference into an owning edge is refused" {
	const message = refused(CAST + "a.kids.push(shared[0] as Owned<N>);\n");
	assert message.contains("cannot cast") && message.contains("owning edge"), message;
}

test "a cast of a fresh value into an owning edge is accepted" {
	const r = compileToC(CAST + "a.kids.push(new N() as Owned<N>);\n");
	assert r.ok, r.ok ? "" : r.error;
}

test "a cast through unknown into an owning edge is refused" {
	const message = refused(CAST + "a.kids.push((shared[0] as unknown) as Owned<N>);\n");
	assert message.contains("owning edge") || message.contains("unknown"), message;
}

test "an owned value cast to Owned passes the checker" {
	const message = refused(CAST + "function same(o: Owned<N>): Owned<N> { return o as Owned<N>; }\n");
	assert !message.contains("cannot cast"), message;
}
