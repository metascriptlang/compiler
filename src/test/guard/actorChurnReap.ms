// nim-guard: actor churn + spawn-inside-method — owner-scheduler reap only
//
// INVARIANT (PARALOCK I18/I19, Pony reap discipline): an actor shell is torn
//   down and freed only by its owning scheduler, at a visit's reap gate
//   (processing held, popped off the run queue) or the reap scan — and the
//   scan reaps ONLY suspended-stopped shells, where the latched SUSPENDED
//   flag keeps senders off the wasEmpty edge (no queue entry can exist).
// NIM-REF: PARALOCK §7.4 R1 + Amendments I18/I19, §8 I18/I19.
//
// WHAT IT CATCHES: (a) pre-I18 stop() freed the shell on the caller's thread
//   while scheduler-reachable — deterministic panic "load of value 136/212
//   not valid for bool" at the msActorProcess alive-guard under churn;
//   (b) the I19-era scan race — reaping on `scheduled==false` alone frees a
//   live run-queue node when a sender's wasEmpty push races markEmpty
//   (SIGSEGV in msSchedRunPop at head->runNext, ~1/30 under orc). Proven red
//   on both pre-fix runtimes (2026-07-22).
//
// RED MEANS: shell reclamation drifted off the owner scheduler, or the reap
//   scan widened past the suspended-stopped lane. Run /trace-nim against the
//   Pony reap sites (self-reap at end-of-own-run; no synchronous external kill).
//
// Trigger needs: create/stop churn (fresh shell + reap per iteration) AND
// await-spawn inside the method (suspension + resume traffic on pool workers
// racing the owner's polls). Run by run.sh (-DMS_DRC_LEDGER, drc+orc).

import { stop, ExitReason } from "std/actor";
import { exit } from "std/process";

actor Churner {
    buf: string;
    constructor() {
        let s = "c";
        for (let i = 0; i < 6; i = i + 1) { s = s + s; }
        this.buf = s;
    }
    run(): int32 {
        let total = 0;
        for (let k = 0; k < 3; k = k + 1) {
            const cc = this.buf;
            const r = await spawn(() => cc.length);
            total = total + r;
        }
        return total;
    }
}

function main(): void {
    let acc = 0;
    for (let n = 0; n < 300; n = n + 1) {
        const w = new Churner();
        const r = await w.run();
        if (r != 192) { exit(1); }
        acc = (acc + r) % 100000;
        stop(w.pid, ExitReason.Normal);
    }
    console.log("actorChurnReap ok acc=" + acc.toString());
}
main();
