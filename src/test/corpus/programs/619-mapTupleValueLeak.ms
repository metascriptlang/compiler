// @xfail(esm): tree emit: prelude container class binding never imported into the referencing module
// @maxrss: 40
// @stdout: map-tuple-value done acc=0
// note: FIXED (tuple not a first-class value type): `Map<int32, [string,string]>` leaked BOTH the incoming and the overwritten tuple's strings on every `m.set` of an existing key. Tuples had no named DRC hooks (only inline expansion in destructorLifting.fillBody), so the analyzer's moveOrCopy at `m.entries[i].value = value` found classify.ms returning empty-named hooks and emitted MS_NIL where the value-STRUCT path emits PairCopy/PairDestroy — the new value was never copied into the slot and the old value was never freed (twin struct-value probe stayed flat at 2.3MB). Three coordinated fixes make tuples first-class (reference parity: of tyTuple == of tyObject): (1) monomorphize monoTypeKey + monoConcreteTypeName add Tuple cases so a mono'd container value `[A,B]` roundtrips through resolveAnnotation back to a Tuple instead of erasing to `unknown`; (2) destructorLifting ensureTupleHooks generates msTuple_<hash>{Destroy,Copy,Sink,WasMoved} over positional fields (named via tupleTypeName — the SAME function codegen uses, so names can't drift) and classify.ms Tuple arm returns Named(tupleTypeName); (3) codegen forward.ms ensureDrcProto emits the cross-module forward proto for msTuple_ hooks (the ms prefix otherwise skipped them). Was 504MB @ 200k, now ~2.3MB drc+orc.

// Guards the Map<K, tuple-value> overwrite leak. `Map<int32, [string, string]>`
// leaked BOTH the incoming and the overwritten tuple's strings on every `m.set`
// of an existing key: tuples had no named DRC hooks, so the analyzer's moveOrCopy
// emitted MS_NIL where the value-struct path emits PairCopy/PairDestroy — the new
// value was never copied into the slot and the old value was never freed.
// Fix (first-class tuple value type): destructorLifting ensureTupleHooks generates
// msTuple_<hash>{Destroy,Copy,Sink,WasMoved}, classify.ms returns Named(tupleTypeName),
// forward.ms emits the cross-module proto. Was 504MB @ 200k, now ~2.3MB drc+orc.
// Only the native binary runs the C lifecycle hooks.

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
