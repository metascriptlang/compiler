// @stdout: 8 104 true
// @stdout: done
// note: a module const the checker judges immutable is marked immortal (a deep-Readonly class graph, a Readonly struct, a Sendable function, a const-frozen struct holding one); eight actors store it from their methods and a spawn returns a value reached from it, every count goes through the Ro flavor, so === holds across threads and the SAN ledger stays balanced.
class Leaf { n: int32 = 1; }
class Node { next: Node | null = null; leaf: Leaf = new Leaf(); }
function chain(): Node { const a = new Node(); a.next = new Node(); return a; }
const EMPTY: Readonly<Node> = chain();
struct W { leaf: Leaf; tag: int32; }
const KW: Readonly<W> = { leaf: new Leaf(), tag: 3 };
type Handler = (n: int32) => int32;
function mk(b: int32, tag: string): Sendable<Handler> { return (n: int32): int32 => n + b + tag.length; }
const F: Sendable<Handler> = mk(3, "four");
struct Table { name: string; columns: Vec<string>; keyOf: Sendable<Handler>; }
const accounts: Table = { name: "accounts", columns: ["id", "balance"], keyOf: mk(1, "x") };

actor Tree {
	head: Readonly<Node> | null = null;
	w: Readonly<W> | null = null;
	f: Sendable<Handler> | null = null;
	t: Table | null = null;
	reset(): void { this.head = EMPTY; this.w = KW; this.f = F; this.t = accounts; }
	isEmpty(): boolean { return this.head === EMPTY && this.w!.leaf === KW.leaf; }
	run(n: int32): int32 { return this.f!(n) + this.t!.keyOf(n) + this.t!.columns.length; }
}

async function main(): Promise<void> {
	const trees: Tree[] = [];
	for (let i = 0; i < 8; i += 1) trees.push(new Tree());
	for (const t of trees) t.reset();
	let ok = 0;
	for (const t of trees) { if (await t.isEmpty()) ok += 1; }
	let sum = 0;
	for (const t of trees) sum += await t.run(1);
	const next = spawn((): Readonly<Node> | null => EMPTY.next);
	const got = await next;
	console.log(ok, sum, got === EMPTY.next);
}
await main();
console.log("done");
