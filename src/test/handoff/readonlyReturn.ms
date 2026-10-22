import { checkProjectDiagnostics } from "../helpers";

function errors(source: string, text: string): int32 {
	let n: int32 = 0;
	for (const m of checkProjectDiagnostics([{ entryPath: "src/main.ms", entrySource: source }], "src/main.ms")) {
		if (m.indexOf(text) >= 0) n += 1;
	}
	return n;
}

const node = "class Node { kids: Node[] = []; n: int32 = 0; }\n";
const owning = "declare the owning result type 'Node' to return it";
const mixed = "split 'mk' into a view routine and an owning one, or return an explicit structural copy of the view (clone or spread) under the owning result type 'Node'";

test "readonlyReturn: a path from any view parameter, a view call or null is a borrow" {
	assert errors(node + "function f(t: Readonly<Node>): Readonly<Node> { return t.kids[0]; }", "") == 0;
	assert errors(node + "function f(a: Readonly<Node>, b: Readonly<Node>): Readonly<Node> { return a.n > 0 ? a : b.kids[0]; }", "") == 0;
	assert errors(node + "function g(t: Readonly<Node>): Readonly<Node> { return t; }\nfunction f(t: Readonly<Node>): Readonly<Node> { return g(t).kids[0]; }", "") == 0;
	assert errors(node + "function f(t: Readonly<Node>): Readonly<Node> | null { return t.kids.length == 0 ? null : t.kids[0]; }", "") == 0;
	assert errors(node + "function f(t: Readonly<Node>): Readonly<Node> { return null as unknown as Readonly<Node>; }", "") == 0;
}

test "readonlyReturn: a fresh value alone is refused with the owning result type" {
	assert errors(node + "function mk(t: Readonly<Node>): Readonly<Node> { return new Node(); }", owning) == 1;
	assert errors(node + "function mk(t: Readonly<Node>): Readonly<Node> { const k = t.kids[0]; return k; }", "escapes its stack frame") == 1;
}

test "readonlyReturn: a fresh arm beside a view arm names both and offers a split or a copy" {
	assert errors(node + "function mk(k: boolean, t: Readonly<Node>): Readonly<Node> {\n\tif (k) return t;\n\treturn new Node();\n}", mixed) == 1;
	assert errors(node + "function mk(k: boolean, t: Readonly<Node>): Readonly<Node> {\n\tif (k) return t;\n\treturn new Node();\n}", "mixes the return at 4:9, which is not a path from a view parameter, with the view return at 3:16") == 1;
	assert errors(node + "function mk(k: boolean, t: Readonly<Node>): Readonly<Node> { return k ? t : new Node(); }", mixed) == 1;
}

test "readonlyReturn: a sink parameter is owned by the routine and cannot be borrowed" {
	assert errors(node + "function f(sink t: Node): Readonly<Node> { return t; }", "is a sink parameter") == 1;
}

test "readonlyReturn: only a Readonly module constant itself is a program-lifetime root" {
	assert errors(node + "const ROOT: Readonly<Node> = new Node();\nfunction f(t: Readonly<Node>): Readonly<Node> { return t.n > 0 ? t : ROOT; }", "") == 0;
	assert errors(node + "let root: Readonly<Node> = new Node();\nfunction f(t: Readonly<Node>): Readonly<Node> { return root; }", "'root' is not a Readonly module constant") == 1;
	assert errors(node + "const ROOT: Node = new Node();\nfunction f(t: Readonly<Node>): Readonly<Node> { return ROOT; }", "'ROOT' is not a Readonly module constant") == 1;
	assert errors(node + "const ROOT: Readonly<Node> = new Node();\nfunction f(t: Readonly<Node>): Readonly<Node> { return ROOT.kids[0]; }", "a path below the module constant 'ROOT'") == 1;
}

test "readonlyReturn: a function value with a Readonly result follows the same rule" {
	assert errors(node + "const f = (t: Readonly<Node>): Readonly<Node> => new Node();", owning) == 1;
	assert errors(node + "const f = (t: Readonly<Node>): Readonly<Node> => t.kids[0];", "") == 0;
}
