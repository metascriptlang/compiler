// nim-guard: a future and a stopped actor's state each count one ledger destroy
//
// INVARIANT: every runtime free of an object allocated with a TypeInfo goes
//   through MS_DESTROY_DISPATCH, so the ledger pairs its alloc with exactly one
//   destroy. Futures are freed by msFutureDestroyInner (runtime/promise/future.h)
//   and a stopped actor's state by its teardown (runtime/actor/actor.h); both
//   skipped the ledger before, which made every future and every stopped
//   actor state read as never destroyed and kept a second free invisible.
//
// RED MEANS: a balance line shows destroy=0 (the free left the ledger again)
//   or DOUBLE-DESTROY aborts (a future or actor state is freed twice). Proven
//   RED both ways on 2026-10-21: without the two dispatch calls (msFuture and
//   Station destroy=0), and with msFutureDestroyInner dispatching twice
//   (DOUBLE-DESTROY of msFuture).
// GUARD-BALANCE msFuture
// GUARD-BALANCE Station

import { stop, ExitReason } from "std/actor";

actor Station {
	data: number[] = [1, 2, 3, 4];
	count(): number { return this.data.length; }
}

async function tick(x: int32): Promise<int32> { return x; }

async function loop(n: int32): Promise<int32> {
	let acc: int32 = 0;
	for (let i: int32 = 0; i < n; i = i + 1) {
		acc = (acc + await tick(i)) % 1000;
	}
	return acc;
}

function main(): void {
	const r = await loop(2000);
	for (let i: int32 = 0; i < 500; i = i + 1) {
		tick(i);
	}
	for (let i = 0; i < 500; i = i + 1) {
		const s = new Station();
		stop(s.pid, ExitReason.Normal);
	}
	console.log(`GUARD-OK ${r}`);
}
main();
