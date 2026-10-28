// @stdout: busy 16
// @stdout: nap 24
// @stdout: chain 18
// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// note: actors on worker schedulers that are busy, suspended on a timer, or awaiting another actor keep the awaiting main thread alive; the unsettled-await check sees them through the parked-worker snapshot and must not end the program with exit 13.

import { stop, ExitReason } from "std/actor";

actor W { work(ms: int32): int32 { const t = Date.now(); while (Date.now() - t < ms) {} return 1; } }
actor S { nap(): int32 { await sleepAsync(60); return 3; } }
actor B { slow(): int32 { await sleepAsync(40); const t = Date.now(); while (Date.now() - t < 20) {} return 2; } }
actor A {
	b: B = new B();
	go(): int32 { return 1 + await this.b.slow(); }
	onTerminate(reason: ExitReason): void { stop(this.b.pid, ExitReason.Normal); }
}

const ws: W[] = [];
for (let i = 0; i < 16; i++) ws.push(new W());
let busy = 0;
for (const w of ws) busy = busy + await w.work(8);
console.log(`busy ${busy}`);

const ss: S[] = [];
for (let i = 0; i < 8; i++) ss.push(new S());
let nap = 0;
for (const x of ss) nap = nap + await x.nap();
console.log(`nap ${nap}`);

const as: A[] = [];
for (let i = 0; i < 6; i++) as.push(new A());
let chain = 0;
for (const a of as) chain = chain + await a.go();
console.log(`chain ${chain}`);

for (const w of ws) stop(w.pid, ExitReason.Normal);
for (const x of ss) stop(x.pid, ExitReason.Normal);
for (const a of as) stop(a.pid, ExitReason.Normal);
