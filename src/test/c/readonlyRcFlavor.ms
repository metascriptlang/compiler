import { compileToC } from "../helpers";

const SOURCE = `
class Leaf { n: int32 = 1; }
class Node { next: Node | null = null; leaf: Leaf = new Leaf(); }
class Holder { node: Readonly<Node> | null = null; leaf: Readonly<Leaf> = new Leaf(); plain: Leaf = new Leaf(); }
const EMPTY: Readonly<Node> = new Node();
function keep(h: Holder, n: Readonly<Node>): void { h.node = n; }
function run(): void {
	const h = new Holder();
	const local: Readonly<Node> = EMPTY;
	keep(h, local);
	const l2: Readonly<Leaf> = h.leaf;
	h.leaf = l2;
	h.plain = new Leaf();
	console.log(h.node === EMPTY, l2.n);
}
run();
`;

function holderDestroyBody(c: string): string {
	const lines = c.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		if (!lines[i].startsWith("void Holder__") || !lines[i].contains("Destroy(") || !lines[i].endsWith("{")) continue;
		const body: string[] = [];
		let j = i + 1;
		while (j < lines.length && lines[j] != "}") { body.push(lines[j].trim()); j += 1; }
		return body.join("\n");
	}
	return "";
}

function count(text: string, needle: string): int32 {
	return text.split(needle).length - 1;
}

test "readonlyRcFlavor: a count reached through Readonly<T> takes the Ro flavor of its RC ops, every other count keeps the plain op" {
	const result = compileToC(SOURCE);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("msIncrefRo(") && c.contains("msDecrefRo("), "acyclic Readonly<Leaf>";
	assert c.contains("msIncrefCyclicRo(") && c.contains("msDecrefCyclicRo("), "cyclic Readonly<Node>";
	const destroy = holderDestroyBody(c);
	assert count(destroy, "msDecref(") == 1, "the mutable field 'plain' keeps the plain op:\n" + destroy;
	assert count(destroy, "msDecrefRo(") == 1, "the Readonly<Leaf> field takes the Ro op:\n" + destroy;
	assert count(destroy, "msDecrefCyclicEdgeRo(") == 1, "the Readonly<Node> field of a cyclic owner drops through the Ro edge:\n" + destroy;
}
