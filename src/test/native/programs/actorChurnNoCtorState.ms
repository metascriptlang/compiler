// Guards the NO-constructor actor teardown path — a distinct codegen branch from the
// with-ctor one (actorChurnHeapState.ms). A no-ctor actor's `new` goes through the
// Ref-with-field-defaults branch (already passes innerType to ensureTypeInfoDef), so
// its state TypeInfo.destroyFn is wired and the runtime msActorDestroyWithReason frees
// the state's heap fields. Without the runtime free this leaked the heap array on every
// teardown. Churn create+stop and bound RSS. Invisible to test-ms (Bun JS-GC).

import { stop, ExitReason } from "std/actor";

actor Light {
	data: number[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40];
	count(): number { return this.data.length; }
}

function main(): void {
	let acc = 0;
	for (let i = 0; i < 200000; i = i + 1) {
		const a = new Light();
		if (a.pid !== 0) { acc = (acc + 1) % 1000; }
		stop(a.pid, ExitReason.Normal);
	}
	console.log(`actor-churn-noctor done acc=${acc}`);
}
main();
