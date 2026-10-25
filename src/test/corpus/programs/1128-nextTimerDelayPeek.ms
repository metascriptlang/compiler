// @stdout: peek none=-1 armed=true fired=false overdue=0 after=-1
// @skip-js: msNextTimerDelayMs is the C runtime's host API for an embedding event loop
// @skip-raiser: the Raiser VM has no C runtime timer heap to read
import { performance } from "std/core/performance";

extern function msNextTimerDelayMs(): int32;

let fired = false;
const none = msNextTimerDelayMs();
const armed = setTimeout(() => { fired = true; }, 50);
const delay = msNextTimerDelayMs();
const overdueId = setTimeout(() => {}, 1);
const start = performance.now();
while (performance.now() - start < 5) {}
const overdue = msNextTimerDelayMs();
clearTimeout(armed);
clearTimeout(overdueId);
setTimeout(() => {
	console.log("peek", `none=${none}`, `armed=${delay >= 40 && delay <= 50}`, `fired=${fired}`, `overdue=${overdue}`, `after=${msNextTimerDelayMs()}`);
}, 60);
