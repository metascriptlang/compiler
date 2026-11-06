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

test "immortalConstMark: a deep-Readonly module const built fresh is marked immortal after its initializer, through a lifted reach hook; a mutable const and an alias of one stay mortal" {
	const result = compileToC(SOURCE);
	assert result.ok, result.ok ? "" : result.error;
	const c = result.ok ? result.value : "";
	assert c.contains("msImmortalize(EMPTY__"), "the fresh Readonly const is marked";
	assert !c.contains("msImmortalize(PLAIN__"), "a const typed mutable stays mortal";
	assert !c.contains("msImmortalize(ALIAS__"), "a Readonly alias of a mutable const reaches cells the const does not own, so it stays mortal";
	assert c.contains("Node__") && c.contains("Reach("), "the walk goes through a lifted reach hook";
}
