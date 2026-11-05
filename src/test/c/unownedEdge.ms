// Unowned<T> is a stored edge counted on its target's second count: it keeps the class out of
// the cycle collector, a store counts it, the holder's destroy releases it, and a read never
// moves it into a strong owner. Runtime behaviour: corpus `unownedEdgeReadsItsTarget` and its `unownedEdge*` siblings.

import { compileToC } from "../helpers";

function typeInfoOf(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(`msTypeInfo ${name}`) && line.contains(`.name = "${name}"`)) return line;
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

function emitted(src: string): string {
	const r = compileToC(src);
	return r.ok ? r.value : r.error;
}

test "an Unowned back edge is acyclic" {
	assert verdict("class N { up: Unowned<N> | null = null; }\nconst n = new N();", "N") == "acyclic";
}

test "a plain back edge is cyclic" {
	assert verdict("class N { up: N | null = null; }\nconst n = new N();", "N") == "cyclic";
}

test "owned children with an Unowned parent edge are acyclic" {
	assert verdict("class N { kids: Vec<Owned<N>> = []; up: Unowned<N> | null = null; }\nconst n = new N();", "N") == "acyclic";
	assert verdict("class N { left: Owned<N> | null = null; up: Unowned<N> | null = null; }\nconst n = new N();", "N") == "acyclic";
}

test "a store into an Unowned slot counts on the second count" {
	const c = emitted("class T { id: int32 = 0; }\nclass H { at: Unowned<T> | null = null; }\nconst t = new T();\nconst h = new H();\nh.at = t;\nconsole.log(t.id);\n");
	assert c.contains("msUnownedAssign"), c;
	assert c.contains("msUnownedDecref"), c;
}

test "a literal's Unowned field takes its value on the second count, not a strong copy" {
	const element = emitted("class T { id: int32 = 4; }\nstruct V { at: Unowned<T> | null; tag: int32; }\nfunction f(t: T): int32 {\n\tconst vs: V[] = [{ at: t, tag: 1 }];\n\treturn vs.length;\n}\nconsole.log(f(new T()));\n");
	assert element.contains("msUnownedTake(t_p0)"), element;
	assert !element.contains("msIncref(t_p0)"), element;
	const returned = emitted("class T { id: int32 = 4; }\nstruct V { at: Unowned<T> | null; tag: int32; }\nfunction f(t: T): V { return { at: t, tag: 2 }; }\nconst t = new T();\nconsole.log(f(t).tag);\n");
	assert returned.contains("msUnownedTake(t_p0)"), returned;
}

test "the last read of an Unowned field is a copy, not a move" {
	const c = emitted("class T { id: int32 = 4; }\nstruct V { at: Unowned<T> | null; }\nfunction f(t: T): int32 {\n\tlet v: V = { at: null };\n\tv.at = t;\n\tconst r = v.at;\n\treturn r != null ? r.id : 0;\n}\nconsole.log(f(new T()));\n");
	assert !c.contains("msPtrWasMoved(v_1_.at)"), c;
}

test "Unowned is a field type: a local, a parameter, a return or a static that names it is refused" {
	const head = "class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\n";
	assert emitted(head + "const n = new N();\nconst p: Unowned<N> | null = n;\nconsole.log(p != null);\n").contains("Unowned<T> is the type of a class or struct field");
	assert emitted(head + "function f(x: Unowned<N>): int32 { return 0; }\nconsole.log(f(new N()));\n").contains("Unowned<T> is the type of a class or struct field");
	assert emitted(head + "function f(h: H): Unowned<N> | null { return h.at; }\nconsole.log(f(new H()) == null);\n").contains("Unowned<T> is the type of a class or struct field");
	assert emitted(head + "class S { static at: Unowned<N> | null = null; }\nconsole.log(S.at == null);\n").contains("Unowned<T> is the type of a class or struct field");
}

test "an Unowned edge inside an element or a type argument is refused until it is counted there" {
	const head = "class N { id: int32 = 1; }\n";
	const tail = "console.log(new H().ups.size >= 0);\n";
	assert emitted(head + "class H { ups: Vec<Unowned<N>> = []; }\nconsole.log(new H().ups.length);\n").contains("an element or a type argument is not built yet");
	assert emitted(head + "class H { ups: Unowned<N>[] = []; }\nconsole.log(new H().ups.length);\n").contains("an element or a type argument is not built yet");
	assert emitted(head + "class H { ups: Unowned<N>[][] = []; }\nconsole.log(new H().ups.length);\n").contains("an element or a type argument is not built yet");
	assert emitted(head + "class H { ups: (Unowned<N> | null)[] = []; }\nconsole.log(new H().ups.length);\n").contains("an element or a type argument is not built yet");
	assert emitted(head + "class H { ups: Map<string, Unowned<N>> = new Map(); }\n" + tail).contains("an element or a type argument is not built yet");
}

test "a value holding an Unowned edge does not cross a thread by move, reply or spawn result" {
	const head = "class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\n";
	const refused = "holding an Unowned edge is not sendable";
	assert emitted(head + "actor A { n: int32 = 0; take(h: H): void { this.n = h.at != null ? 1 : 0; } }\nfunction f(): void { const h = new H(); const a = new A(); a.take(move h); }\nf();\n").contains(refused);
	assert emitted(head + "actor A { make(): H { return new H(); } }\nasync function g(): Promise<int32> { const a = new A(); const h = await a.make(); return h.at == null ? 0 : 1; }\nconsole.log(await g());\n").contains(refused);
	assert emitted(head + "async function g(): Promise<int32> { const h = new H(); const t = spawn(() => { return h.at != null ? 1 : 0; }, { move: [h] }); return await t; }\nconsole.log(await g());\n").contains(refused);
	assert emitted(head + "class W { h: H = new H(); }\nasync function g(): Promise<int32> { const w = new W(); const t = spawn(() => { return w.h.at != null ? 1 : 0; }, { move: [w] }); return await t; }\nconsole.log(await g());\n").contains(refused);
	assert emitted(head + "async function g(): Promise<int32> { const t = spawn(() => { return new H(); }); const h = await t; return h.at == null ? 0 : 1; }\nconsole.log(await g());\n").contains(refused);
}

test "a value holding an Unowned edge is still lent to an awaited actor call and a spawn that reads it" {
	const head = "class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\n";
	assert !emitted(head + "actor A { weigh(h: H): int32 { return h.at != null ? h.at.id : 0; } }\nasync function g(): Promise<int32> { const n = new N(); const h = new H(); h.at = n; const a = new A(); return await a.weigh(h); }\nconsole.log(await g());\n").contains("not sendable");
	assert !emitted(head + "async function g(): Promise<int32> { const n = new N(); const h = new H(); h.at = n; const t = spawn(() => { return h.at != null ? h.at.id : 0; }); return await t; }\nconsole.log(await g());\n").contains("not sendable");
}

test "a local bound to an Unowned read is a plain reference, so storing into it is a strong store" {
	const c = emitted("class N { id: int32 = 1; }\nclass H { at: Unowned<N> | null = null; }\nfunction f(h: H, m: N): int32 {\n\tlet p = h.at;\n\tp = m;\n\treturn p != null ? p.id : 0;\n}\nconst n = new N();\nconst h = new H();\nh.at = n;\nconsole.log(f(h, n));\n");
	assert !c.contains("msUnownedAssign((&(p_1_))"), c;
	assert !c.contains("error"), c;
}

test "Unowned takes a class" {
	assert emitted("const v: Unowned<string> | null = null;\nconsole.log(v);\n").contains("Unowned<T> takes a class type");
	assert emitted("struct S { a: int32 }\nclass H { s: Unowned<S> | null = null; }\nconsole.log(new H().s == null);\n").contains("Unowned<T> takes a class type");
}
