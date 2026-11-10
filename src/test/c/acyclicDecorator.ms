// @acyclic is removed from the language: a class leaves the cycle collector only through Owned<T> and
// Unowned<T> edges (c/ownedEdge.ms, c/unownedEdge.ms), so the decorator is refused wherever it is written.

import { compileToC } from "../helpers";

function typeInfoOf(c: string, name: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(`msTypeInfo ${name}`) && line.contains(`.name = "${name}"`)) return line;
	}
	return "";
}

const NODE = `class Node {
	next: Node | null = null;
}
const a = new Node();
a.next = new Node();
console.log("ok");
`;

const REMOVED = "@acyclic is removed from the language: a class leaves the cycle collector when its owning edges are Owned<T> and its edges back are Unowned<T>";

test "E2E C: a self-referencing class registers for cycle collection" {
	const r = compileToC(NODE);
	assert r.ok, r.ok ? "" : r.error;
	assert typeInfoOf(r.ok ? r.value : "", "Node").contains(".isCyclic = MS_TRUE");
}

test "E2E C: @acyclic on a class is refused, naming Owned and Unowned" {
	const r = compileToC("@acyclic\n" + NODE);
	assert !r.ok;
	assert (r.ok ? "" : r.error).contains(REMOVED);
}

test "E2E C: @acyclic on an extended class or a function is refused the same way" {
	const base = compileToC("@acyclic\nclass Base { next: Base | null = null; }\nclass Leaf extends Base { tag: int32 = 0; }\nconst a = new Leaf();\nconsole.log(a.tag);\n");
	assert !base.ok && (base.ok ? "" : base.error).contains(REMOVED);
	const fn = compileToC("@acyclic\nfunction f(): int32 { return 1; }\nconsole.log(f());\n");
	assert !fn.ok && (fn.ok ? "" : fn.error).contains(REMOVED);
}

test "E2E C: a class whose edge back is Unowned leaves the collector without a decorator" {
	const r = compileToC("class Node {\n\tup: Unowned<Node> | null = null;\n\tv: int32 = 0;\n}\nconst a = new Node();\nconsole.log(a.v);\n");
	assert r.ok, r.ok ? "" : r.error;
	assert typeInfoOf(r.ok ? r.value : "", "Node").contains(".isCyclic = MS_FALSE");
}
