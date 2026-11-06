import { compileToC } from "../helpers";

const SOURCE = `
class Leaf { n: int32 = 1; }
class Node { next: Node | null = null; leaf: Leaf = new Leaf(); }
function chain(): Node { const a = new Node(); a.next = new Node(); return a; }
const EMPTY: Readonly<Node> = chain();
const PLAIN = new Node();
const ALIAS: Readonly<Node> = PLAIN;
console.log(EMPTY.next != null, PLAIN.leaf.n, ALIAS === PLAIN);
`;

const STRUCTS = `
class Leaf { n: int32 = 1; }
struct W { leaf: Leaf; tag: int32; }
class Node { w: W = { leaf: new Leaf(), tag: 7 }; }
const KW: Readonly<W> = { leaf: new Leaf(), tag: 3 };
const EMPTY: Readonly<Node> = new Node();
class H { w: Readonly<W> | null = null; plain: W | null = null; }
const h = new H();
h.w = EMPTY.w;
h.plain = { leaf: new Leaf(), tag: 1 };
const copy: Readonly<W> = KW;
console.log(copy.tag, h.w!.tag, h.plain!.tag);
`;

test "immortalConstMark: a Readonly<S> value copies through its own hook pair, whose fields count through the Ro flavor, and a struct const is marked through its Ro reach hook" {
	const result = compileToC(STRUCTS);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("RoReach((&(KW__") && c.contains("msImmortalBegin())") && c.contains("msImmortalEnd();"), "the struct const is marked through the reach hook of its view";
	assert c.contains("W__") && c.contains("RoCopy("), "a Readonly<W> copy calls the Ro hook pair";
	const roCopy = hookBody(c, "W__", "RoCopy(");
	assert roCopy.contains("msIncrefRo(") && !roCopy.contains("msIncRef(") && !roCopy.contains("msIncref("), "the Ro copy hook counts its field through the Ro flavor:\n" + roCopy;
	const plainCopy = hookBody(c, "W__", "Copy(", "RoCopy(");
	assert plainCopy.contains("msIncref(") && !plainCopy.contains("msIncrefRo("), "the plain W copy hook keeps the plain op:\n" + plainCopy;
}

const CLOSURES = `
type Handler = (n: int32) => int32;
function mk(b: int32): Sendable<Handler> { return (n: int32): int32 => n + b; }
const F: Sendable<Handler> = mk(3);
console.log(F(1));
`;

test "immortalConstMark: a Sendable function const has its env marked after its initializer" {
	const result = compileToC(CLOSURES);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("msImmortalizeClosure("), "the Sendable function const marks its env";
}

function hookBody(c: string, prefix: string, suffix: string, notSuffix: string = ""): string {
	const lines = c.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		const l = lines[i];
		if (!l.startsWith("void " + prefix) || !l.contains(suffix) || !l.endsWith("{")) continue;
		if (notSuffix != "" && l.contains(notSuffix)) continue;
		const body: string[] = [];
		let j = i + 1;
		while (j < lines.length && lines[j] != "}") { body.push(lines[j].trim()); j += 1; }
		return body.join("\n");
	}
	return "";
}

test "immortalConstMark: a deep-Readonly module const built fresh is marked immortal after its initializer, through a lifted reach hook; a mutable const and an alias of one stay mortal" {
	const result = compileToC(SOURCE);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("msImmortalize(EMPTY__"), "the fresh Readonly const is marked";
	assert !c.contains("msImmortalize(PLAIN__"), "a const typed mutable stays mortal";
	assert !c.contains("msImmortalize(ALIAS__"), "a Readonly alias of a mutable const reaches cells the const does not own, so it stays mortal";
	assert c.contains("Node__") && c.contains("Reach("), "the walk goes through a lifted reach hook";
}
