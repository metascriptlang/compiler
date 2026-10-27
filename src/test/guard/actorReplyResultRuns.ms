// An actor reply `Result.ok(fresh)` of a payload that holds a ref is a sole-owned reply
//
// INVARIANT (ULTRALOCK V0): `Result.ok` and `Result.err` only wrap their arguments, so the reply is
//   as fresh as the arguments are: a literal, a moved local, a `new` or a spread copy. A reply that
//   wraps state the actor keeps stays refused (actorReplyResultRejects.ms).
//
// RED MEANS: a call to the Result builders counts as a side effect, so a fresh payload is refused.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

class Node { n: int32 = 0; }

actor Holder {
	keys: Vec<uint8> = [1, 2];

	literal(): Result<Vec<uint8>, string> { return Result.ok([1, 2]); }
	moved(): Result<Vec<uint8>, string> {
		let v: Vec<uint8> = [3, 4];
		return Result.ok(move v);
	}
	copy(): Result<Vec<uint8>, string> { return Result.ok([...this.keys]); }
	failure(): Result<Vec<uint8>, string> { return Result.err("no"); }
	made(): Result<Node, string> { return Result.ok(new Node()); }
	poke(): int32 { this.keys[0] = 99; return 0; }
}

async function main(): Promise<void> {
	const h = new Holder();
	const a = await h.literal();
	const b = await h.moved();
	const c = await h.copy();
	const d = await h.failure();
	const e = await h.made();
	await h.poke();
	stop(h.pid, ExitReason.Normal);
	if (!a.ok || !b.ok || !c.ok || d.ok || !e.ok) throw new Error(`${a.ok} ${b.ok} ${c.ok} ${d.ok} ${e.ok}`);
	if (c.value[0] != 1 || b.value.length != 2) throw new Error(`c0=${c.value[0]}`);
	console.log("GUARD-OK");
}

await main();
