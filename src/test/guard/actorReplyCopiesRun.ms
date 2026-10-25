// An actor replies with a copy or a fresh value, and the caller's writes stay its own
//
// INVARIANT (ULTRALOCK V0, V1, V2): a reply that is a number, a string, a plain struct, a Result
//   of those, or a value built for the reply (`new`, a literal, a spread of numbers, a local nothing else
//   keeps) crosses. An Arc<T> reply: actorReplyArcRuns.ms. The actor's own state is refused:
//   actorReplyStateRejects.ms.
//
// RED MEANS: the reply rule refuses a copy, or a caller's write reaches the actor's state.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

class Node { hits: int32 = 0; name: string = "n"; }
struct Pair { a: int32; b: string; }

actor Scene {
	top: Node = new Node();
	hits: int32[] = [1, 2];
	count(): int32 { return this.top.hits; }
	name(): string { return this.top.name; }
	pair(): Pair { return { a: this.top.hits, b: this.top.name }; }
	result(): Result<int32, string> { return Result.ok(this.top.hits); }
	fresh(): Node { return new Node(); }
	copyOf(): Node {
		const n = new Node();
		n.hits = this.top.hits;
		n.name = this.top.name;
		return n;
	}
	list(): int32[] { return [...this.hits]; }
	bump(): int32 { this.top.hits = this.top.hits + 1; return this.top.hits; }
}

async function main(): Promise<void> {
	const s = new Scene();
	await s.bump();
	const c = await s.copyOf();
	c.hits = 100;
	const xs = await s.list();
	xs[0] = 100;
	const f = await s.fresh();
	f.hits = 7;
	const p = await s.pair();
	const r = await s.result();
	const n = await s.count();
	const nm = await s.name();
	stop(s.pid, ExitReason.Normal);
	if (n != 1 || c.hits != 100 || xs.length != 2 || p.a != 1 || !r.ok || p.b != "n" || nm != "n") throw new Error(`reply: n=${n} p=${p.a}`);
	console.log("GUARD-OK");
}

await main();
