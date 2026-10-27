// A Sendable function calls a captured actor's method, whatever that method does to the actor's own state
//
// INVARIANT (ULTRALOCK actors): an actor method call is a message, so the method body runs on the
//   actor's executor and is not part of the closure's task. The closure's crossing check follows the
//   call's operands, not the body: iterating or deleting from a Map field, or calling a function
//   value the method builds, stays inside the actor. Message arguments are checked at the send
//   (actorCallInSendableRejects.ms).
//
// RED MEANS: the crossing check walks into an actor method body as if the closure ran it.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

class Item { n: int32 = 1; }
struct Host { put: (n: int32) => int32; }

actor Hub {
	items: Map<string, Item> = new Map();
	total: int32 = 0;

	add(name: string): int32 { this.items.set(name, new Item()); return this.items.size as int32; }
	forget(): int32 { for (const item of this.items.values()) { item.n = 0; } return this.items.size as int32; }
	remove(name: string): int32 { this.items.delete(name); return this.items.size as int32; }
	put(n: int32): int32 {
		const host: Host = { put: (v: int32): int32 => { this.total += v; return this.total; } };
		const put = host.put;
		return put(n);
	}
}

function makeAdd(hub: Hub): Sendable<(name: string) => Promise<int32>> {
	return async (name: string): Promise<int32> => await hub.add(name);
}
function makeForget(hub: Hub): Sendable<() => Promise<int32>> {
	return async (): Promise<int32> => await hub.forget();
}
function makeRemove(hub: Hub): Sendable<(name: string) => Promise<int32>> {
	return async (name: string): Promise<int32> => await hub.remove(name);
}
function makePut(hub: Hub): Sendable<(n: int32) => Promise<int32>> {
	return async (n: int32): Promise<int32> => await hub.put(n);
}

async function main(): Promise<void> {
	const hub = new Hub();
	const a = await makeAdd(hub)("x");
	const b = await makeAdd(hub)("y");
	const c = await makeForget(hub)();
	const d = await makeRemove(hub)("x");
	const e = await makePut(hub)(2);
	const f = await makePut(hub)(3);
	stop(hub.pid, ExitReason.Normal);
	if (a != 1 || b != 2 || c != 2 || d != 1 || e != 2 || f != 5) throw new Error(`a=${a} b=${b} c=${c} d=${d} e=${e} f=${f}`);
	console.log("GUARD-OK");
}

await main();
