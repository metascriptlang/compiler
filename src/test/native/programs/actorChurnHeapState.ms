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
		if (a.pid !== 0) { acc = (acc + 1) % 1000; }
		stop(a.pid, ExitReason.Normal);
	}
	console.log(`actor-churn-heapstate done acc=${acc}`);
}
main();
