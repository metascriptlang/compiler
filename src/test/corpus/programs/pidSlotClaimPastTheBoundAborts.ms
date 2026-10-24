// @exit: 1
// @stdout: fatal: pid table full
// @skip-js: the JS backend has no pid table
// @xfail(raiser): the Raiser VM has no actors: it never reaches the pid table
// note: the slot bound is lowered to 4, so the fifth live actor claims past it; the claim must name the failure and exit instead of writing past the segment table.
import { stop, ExitReason } from "std/actor";

@passC("-DMS_TEST_PID_SLOT_LIMIT=4");

actor Cell {
	n: int32 = 0;
	ping(): int32 { this.n = this.n + 1; return this.n; }
}

const live: Cell[] = [];
for (let i = 0; i < 8; i++) {
	live.push(new Cell());
	await live[i].ping();
}
console.log("claimed every slot without a bound");
