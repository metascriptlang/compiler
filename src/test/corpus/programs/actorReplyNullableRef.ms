// @stdout: node null=true
// @stdout: node hits=7
// @stdout: node null=true
// @stdout: str null=true
// @stdout: str hello
// @stdout: arr null=true
// @stdout: arr 3
// @stdout: box 5 null=true
// @stdout: box 5 hits=9
// @stdout: arg -1
// @stdout: arg 9
// @exit: 0
// @serial
// @ledger-slack(Scene) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: an actor method that replies a nullable reference (class, array), as a reply or an argument, delivers that reference itself, and null stays null; a string or struct union is boxed by the reply and unboxed by the await. Old compiler: the reply boxed every union, the await read a nullable reference unboxed, so a null reply arrived as a non-null box address.

class Node { hits: int32 = 0; }
struct Box { n: int32; node: Node | null; }

actor Scene {
	flip: int32 = 0;
	node(): Node | null {
		this.flip += 1;
		if (this.flip % 2 == 0) { const n = new Node(); n.hits = 7; return n; }
		return null;
	}
	str(on: boolean): string | null { return on ? "hello" : null; }
	arr(on: boolean): int32[] | null { return on ? [1, 2, 3] : null; }
	size(n: Node | null): int32 { return n == null ? -1 : n.hits; }
	box(on: boolean): Box { return on ? { n: 5, node: makeNode() } : { n: 5, node: null }; }
}

function makeNode(): Node { const n = new Node(); n.hits = 9; return n; }

async function main(): Promise<void> {
	const s = new Scene();
	const a = await s.node();
	console.log(`node null=${a == null}`);
	const b = await s.node();
	console.log(`node hits=${b!.hits}`);
	const c = await s.node();
	console.log(`node null=${c == null}`);
	const s0 = await s.str(false);
	console.log(`str null=${s0 == null}`);
	const s1 = await s.str(true);
	console.log(`str ${s1!}`);
	const r0 = await s.arr(false);
	console.log(`arr null=${r0 == null}`);
	const r1 = await s.arr(true);
	console.log(`arr ${r1!.length}`);
	const x0 = await s.box(false);
	console.log(`box ${x0.n} null=${x0.node == null}`);
	const x1 = await s.box(true);
	console.log(`box ${x1.n} hits=${x1.node!.hits}`);
	console.log(`arg ${await s.size(null)}`);
	console.log(`arg ${await s.size(makeNode())}`);
}
await main();
