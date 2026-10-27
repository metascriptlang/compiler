// An actor reply built by pushing a spread of scalars beside a fresh class is a copy
//
// INVARIANT (ULTRALOCK V0): `[...this.keys]` over scalar elements is fresh storage nothing in the
//   actor keeps, so a local that holds it beside other fresh values is a sole-owned reply, and the
//   actor changing its own state afterwards leaves the reply as it was. A pushed class the actor
//   keeps stays refused (actorReplySpreadPushedRejects.ms).
//
// RED MEANS: isFreshValue treats a spread of scalars as the state it reads, or the spread aliases it.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

class Node { n: int32 = 0; }
struct Entry { node: Node; key: Vec<uint8>; }

actor Holder {
	keys: Vec<uint8> = [1, 2];
	rows: Vec<Vec<uint8>> = [[5, 6, 7]];

	mixed(): Entry[] {
		let out: Entry[] = [];
		out.push({ node: new Node(), key: [...this.keys] });
		for (const row of this.rows) { out.push({ node: new Node(), key: [...row] }); }
		return out;
	}
	poke(): int32 { this.keys[0] = 99; this.rows[0][0] = 99; return 0; }
}

async function main(): Promise<void> {
	const h = new Holder();
	const a = await h.mixed();
	await h.poke();
	stop(h.pid, ExitReason.Normal);
	if (a.length != 2 || a[0].key[0] != 1 || a[1].key[0] != 5) throw new Error(`n=${a.length} k0=${a[0].key[0]} k1=${a[1].key[0]}`);
	console.log("GUARD-OK");
}

await main();
