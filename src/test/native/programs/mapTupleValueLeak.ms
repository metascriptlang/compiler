// Guards the Map<K, tuple-value> overwrite leak. `Map<int32, [string, string]>`
// leaked BOTH the incoming and the overwritten tuple's strings on every `m.set`
// of an existing key: tuples had no named DRC hooks, so the analyzer's moveOrCopy
// emitted MS_NIL where the value-struct path emits PairCopy/PairDestroy — the new
// value was never copied into the slot and the old value was never freed.
// Fix (first-class tuple value type): destructorLifting ensureTupleHooks generates
// msTuple_<hash>{Destroy,Copy,Sink,WasMoved}, classify.ms returns Named(tupleTypeName),
// forward.ms emits the cross-module proto. Was 504MB @ 200k, now ~2.3MB drc+orc.
// Invisible to test-ms (Bun JS-GC); only the native binary runs the C lifecycle hooks.

import { Map } from "std/core/struct";

function big(seed: number): string {
	let s = "x";
	for (let i = 0; i < 10; i = i + 1) { s = s + s; }
	return s;
}

function main(): void {
	const m = new Map<int32, [string, string]>();
	for (let k = 0; k < 8; k = k + 1) { m.set(k as int32, [big(k), big(k + 1)]); }
	let acc = 0;
	for (let n = 0; n < 200000; n = n + 1) {
		const key = (n % 8) as int32;
		m.set(key, [big(n), big(n + 1)]);
		acc = (acc + m.size) % 1000;
	}
	console.log(`map-tuple-value done acc=${acc}`);
}
main();
