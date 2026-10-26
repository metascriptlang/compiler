// @exit: 1
// @ledger-slack(msFuture) 1
// ledger-slack reason: the pid-table abort ends the process while the await on the fifth Cell is pending, so that future is still live at exit
// @stdout: fatal: pid table full: 4 live actors (limit 4)
// @stdout:   spawning: Cell
// @stdout:   live by type: Cell 2 · Probe 1 · <untyped> 1
// @skip-js: the JS backend has no pid table
// @xfail(raiser): the Raiser VM has no actors: it never reaches the pid table
// note: the slot bound is lowered to 4, so the fifth live actor claims past it; the claim must name the failure, count the live actors by type and exit instead of writing past the segment table.
import { stop, ExitReason } from "std/actor";

@passC("-DMS_TEST_PID_SLOT_LIMIT=4");

actor Cell {
	n: int32 = 0;
	ping(): int32 { this.n = this.n + 1; return this.n; }
}

actor Probe {
	ping(): int32 { return 1; }
}

const probe = new Probe();
await probe.ping();
const live: Cell[] = [];
for (let i = 0; i < 8; i++) {
	live.push(new Cell());
	await live[i].ping();
}
console.log("claimed every slot without a bound");
