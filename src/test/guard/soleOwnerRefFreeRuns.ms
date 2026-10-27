// A value whose type holds no ref moves into an actor call from a parameter or a spread copy
//
// INVARIANT (ULTRALOCK custody, E148): the sole-owner rule protects against an alias that survives
//   the move, so it applies only to a type that can hold a ref. A Vec<uint8>, a struct of scalars and
//   Vecs, or a sink parameter of either is ref-free: the move needs no proof of a fresh binding.
//   A type holding a class or closure stays refused (soleOwnerRefFreeRejects.ms).
//
// RED MEANS: E148 refuses `move` of a ref-free parameter or of a copy of one.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

struct Row { id: int32; bytes: Vec<uint8>; }

actor Store {
	total: int32 = 0;
	put(row: Vec<uint8>): int32 { this.total += row.length as int32; return this.total; }
	putRow(row: Row): int32 { this.total += row.bytes.length as int32 + row.id; return this.total; }
}

async function plainParam(store: Store, row: Vec<uint8>): Promise<int32> {
	return await store.put(move row);
}

async function sinkParam(store: Store, sink row: Vec<uint8>): Promise<int32> {
	return await store.put(move row);
}

async function sinkSpread(store: Store, sink row: Vec<uint8>): Promise<int32> {
	const fresh: Vec<uint8> = [...row];
	return await store.put(move fresh);
}

async function structParam(store: Store, sink row: Row): Promise<int32> {
	return await store.putRow(move row);
}

async function main(): Promise<void> {
	const store = new Store();
	const a = await plainParam(store, [1, 2]);
	const b = await sinkParam(store, [1, 2]);
	const c = await sinkSpread(store, [1, 2]);
	const d = await structParam(store, { id: 1, bytes: [1] });
	stop(store.pid, ExitReason.Normal);
	if (a != 2 || b != 4 || c != 6 || d != 8) throw new Error(`a=${a} b=${b} c=${c} d=${d}`);
	console.log("GUARD-OK");
}

await main();
