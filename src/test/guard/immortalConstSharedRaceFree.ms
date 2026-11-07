// An immortal module const is shared by every thread without a written count
//
// INVARIANT (ULTRALOCK V0, V7): eight actors and eight spawns store, copy, push, splice and release a
//   deep-Readonly class graph, a value reached from it, a Readonly struct, a Sendable function, a
//   const-frozen struct holding one and an Unowned<Readonly<T>> edge to it; every op takes the Ro flavor
//   and skips the immortal header, so no thread writes it, === holds and the ledger stays balanced.
//
// WHAT IT CATCHES: a choice point that reaches the const with a plain op: TSan reports the header write,
//   and the ledger build aborts with PLAIN RC OP ON IMMORTAL.
//
// RED MEANS: an op reached through Readonly or Sendable lost its Ro flavor, or a const was not marked.
//
// GUARD-TSAN

class Leaf { n: int32 = 1; }
class Node { next: Node | null = null; leaf: Leaf = new Leaf(); leaves: Leaf[] = [new Leaf(), new Leaf()]; }
function chain(): Node { const a = new Node(); a.next = new Node(); a.next!.next = new Node(); return a; }
const EMPTY: Readonly<Node> = chain();
struct W { leaf: Leaf; tag: int32; }
const KW: Readonly<W> = { leaf: new Leaf(), tag: 3 };
type Handler = (n: int32) => int32;
function mk(b: int32, tag: string): Sendable<Handler> { return (n: int32): int32 => n + b + tag.length; }
const F: Sendable<Handler> = mk(3, "four");
struct Table { name: string; columns: Vec<string>; keyOf: Sendable<Handler>; }
const accounts: Table = { name: "accounts", columns: ["id", "balance"], keyOf: mk(1, "x") };

class UBox { up: Unowned<Readonly<Node>> | null = null; }

actor Churn {
	heads: Readonly<Node>[] = [];
	ws: Readonly<W>[] = [];
	fs: Sendable<Handler>[] = [];
	leaves: Readonly<Leaf>[] = [];
	t: Table | null = null;
	box: UBox = new UBox();
	round(k: int32): int32 {
		let sum = 0;
		for (let i = 0; i < 200; i += 1) {
			this.heads.push(EMPTY);
			const nx = EMPTY.next;
			if (nx != null) this.heads.push(nx);
			this.ws.push(KW);
			this.fs.push(F);
			this.leaves.push(EMPTY.leaves[i % 2]);
			this.t = accounts;
			this.box.up = EMPTY;
			const g: Sendable<Handler> = this.fs[this.fs.length - 1];
			sum += g(k) + this.t!.keyOf(1) + this.ws[this.ws.length - 1].tag;
			if (this.heads.length > 64) this.heads.splice(0, 32);
			if (this.ws.length > 64) this.ws.splice(0, 32);
			if (this.fs.length > 64) this.fs.splice(0, 32);
			if (this.leaves.length > 64) this.leaves = [];
		}
		return sum;
	}
	same(): boolean { return this.heads[0] === EMPTY || this.heads[0] === EMPTY.next; }
}

async function main(): Promise<void> {
	const actors: Churn[] = [];
	for (let i = 0; i < 8; i += 1) actors.push(new Churn());
	let total = 0;
	for (let r = 0; r < 25; r += 1) {
		const replies: Promise<int32>[] = [];
		for (const a of actors) replies.push(a.round(r));
		for (const p of replies) total += await p;
		const tasks: Promise<Readonly<Node> | null>[] = [];
		for (let i = 0; i < 8; i += 1) tasks.push(spawn((): Readonly<Node> | null => EMPTY.next));
		for (const t of tasks) { if ((await t) !== EMPTY.next) total = -1; }
	}
	let same = 0;
	for (const a of actors) { if (await a.same()) same += 1; }
	if (total > 0 && same == 8) console.log("GUARD-OK");
}
await main();
