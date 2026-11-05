// Unowned<T> is a stored edge counted on its target's second count: it keeps the class out of
// the cycle collector, a store counts it, the holder's destroy releases it, and a read never
// moves it into a strong owner. Runtime behaviour: corpus `unownedTreeUpEdges` and siblings.

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

test "the last read of an Unowned field is a copy, not a move" {
	const c = emitted("class T { id: int32 = 4; }\nstruct V { at: Unowned<T> | null; }\nfunction f(t: T): int32 {\n\tlet v: V = { at: null };\n\tv.at = t;\n\tconst r = v.at;\n\treturn r != null ? r.id : 0;\n}\nconsole.log(f(new T()));\n");
	assert !c.contains("msPtrWasMoved(v_1_.at)"), c;
}

test "Unowned takes a class" {
	assert emitted("const v: Unowned<string> | null = null;\nconsole.log(v);\n").contains("Unowned<T> takes a class type");
	assert emitted("struct S { a: int32 }\nclass H { s: Unowned<S> | null = null; }\nconsole.log(new H().s == null);\n").contains("Unowned<T> takes a class type");
}
