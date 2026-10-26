// An actor's onTerminate may log, call a plain helper and send to another actor
//
// INVARIANT (ULTRALOCK T7, A5): the hook law refuses a spawn, an await or a function-value call in
//   an actor hook, never a send: a send does not pause its sender, even when the receiving method
//   awaits. actorHookSuspendRejects.ms pins the refused shapes.
//
// RED MEANS: the hook law refuses a send or a sync helper, or the hook stops running at stop().
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

function label(n: int32): string { return `n=${n}`; }

actor Log {
	seen: int32 = 0;
	note(n: int32): void { await sleepAsync(1); this.seen = this.seen + n; }
	count(): int32 { return this.seen; }
}

actor Lease {
	log: Log;
	constructor(log: Log) { this.log = log; }
	ping(): int32 { return 1; }
	onTerminate(reason: ExitReason): void {
		this.log.note(7);
		console.log(`terminated ${label(7)}`);
	}
}

const log = new Log();
const a = new Lease(log);
await a.ping();
stop(a.pid, ExitReason.Normal);
await sleepAsync(30);
const seen = await log.count();
console.log(seen == 7 ? "GUARD-OK" : `GUARD-FAIL the hook's send did not arrive, seen=${seen}`);
stop(log.pid, ExitReason.Normal);
