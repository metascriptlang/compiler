// @maxrss: 40
// @stdout: actor-churn-heapstate done
// @serial
// note: FIXED: actor create+stop churn leaked a->state (and its heap string) on every teardown. The actor handle is DRC-exempt (classify.ms: actors are runtime-managed), the spawn-time msIncRef exists only so the cycle detector sees rc>0, and the with-ctor `new` path passed null objType to ensureTypeInfoDef so the state type's TypeInfo.destroyFn was never wired (HeavyDestroy existed but unreferenced). Two coordinated fixes: (1) codegen expressions.ms NewExpr with-ctor branch passes the inner struct type (symmetry with the no-ctor branch) so ensureTypeInfoDef wires destroyFn; (2) runtime msActorDestroyWithReason frees a->state via that destroyFn after onTerminate (Pony: actor heap dies with the actor) — unconditional since the exempt handle and cycle-detector incref mean the actor is the sole owner. Was 1.07GB @ 200k (heap-string state), now ~8MB drc+orc. Only the native binary runs msActorDestroyWithReason; no prior native case churned actor create+destroy.

// Actor create+stop churn with heap-string state — guards the actor-teardown
// state leak. Pre-fix: 1.07GB @ 200k. The actor handle is DRC-exempt (classify.ms),
// the spawn-time msIncRef exists only for the cycle detector's rc>0 check, and the
// with-ctor `new` path passed null objType to ensureTypeInfoDef so the state type's
// TypeInfo.destroyFn was never wired — so a->state (and its heap string) leaked on
// every teardown. Two coordinated fixes: codegen wires destroyFn (expressions.ms
// passes the inner type), runtime msActorDestroyWithReason frees a->state via that
// destroyFn. Now ~8MB. Only the native binary exercises msActorDestroyWithReason.

import { stop, ExitReason } from "std/actor";

actor Heavy {
	buf: string = "";
	constructor() {
		let s = "x";
		for (let i = 0; i < 12; i = i + 1) { s = s + s; }
		this.buf = s;
	}
	size(): number { return this.buf.length; }
}

function main(): void {
	let acc = 0;
	for (let i = 0; i < 200000; i = i + 1) {
		const a = new Heavy();
		if (a.pid != 0) { acc = (acc + 1) % 1000; }
		stop(a.pid, ExitReason.Normal);
	}
	console.log(`actor-churn-heapstate done acc=${acc}`);
}
main();
