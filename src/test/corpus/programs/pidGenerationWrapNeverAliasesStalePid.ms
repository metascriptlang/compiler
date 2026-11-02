// @stdout: churn 40 | pid equals stale 0 | monitor via stale 0 | handle call via stale 0 | stale stop killed live 0
// note: the pid generation is lowered to 4 bits, so the one slot this loop reuses wraps its generation twice; a retired slot must never hand a stale pid to the actor that lives there now. The JS lanes have no pid table and print the same line.
import { stop, monitor, ExitReason } from "std/actor";

@passC("-DMS_TEST_PID_GEN_BITS=4");

actor Cell {
	n: int32 = 0;
	ping(): int32 { this.n = this.n + 1; return this.n; }
}

const first = new Cell();
const stalePid = first.pid;
await first.ping();
stop(first.pid, ExitReason.Normal);

let sameAsStale = 0;
let monitored = 0;
let handleCalls = 0;
let killedLive = 0;
for (let i = 0; i < 40; i++) {
	const c = new Cell();
	await c.ping();
	if (c.pid == stalePid) sameAsStale++;
	if (monitor(c.pid, stalePid) != 0) monitored++;
	try {
		await first.ping();
		handleCalls++;
	} catch (e) {
	}
	stop(stalePid, ExitReason.Normal);
	try {
		await c.ping();
	} catch (e) {
		killedLive++;
	}
	stop(c.pid, ExitReason.Normal);
}
console.log(`churn 40 | pid equals stale ${sameAsStale} | monitor via stale ${monitored} | handle call via stale ${handleCalls} | stale stop killed live ${killedLive}`);
