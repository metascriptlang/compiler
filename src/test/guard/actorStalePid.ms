// nim-guard: actor pid indirection — stale pid ops are clean no-ops
//
// INVARIANT (PARALOCK I19, BEAM ptab semantics): a pid is a generation-checked
//   table handle [gen:27|slot:26], never the shell pointer. msActorFromPid on a
//   dead or reused slot returns NULL; send/stop/link/monitor on a stale pid is
//   a no-op. Slot reuse bumps the generation, so a stale pid can never reach
//   the fresh actor occupying the same slot.
// NIM-REF: PARALOCK §7.4 Amendment I19, §8 I19.
//
// WHAT IT CATCHES: pre-I19 pids were raw shell pointers — stop() on a reaped
//   pid read the freed shell's alive flag (panic: "load of value 240, which is
//   not valid for type 'bool'" at msActorStop), and a stale stop could have
//   killed an unrelated fresh actor. Proven red on the pre-I19 runtime
//   (2026-07-22, deterministic once stale stops follow real reaps).
//
// RED MEANS: the pid table drifted — generation check lost, slot release
//   ordering broken (release must precede teardown), or a scan freed a shell
//   that was still reachable. Crash/hang = lookup UAF; wrong total = a stale
//   pid reached a live actor (generation aliasing).
//
// Trigger needs: real reaps between capture and re-stop (spin lets the owner
// poll), double-stop pre-reap, and slot REUSE under stale fire (fresh actors
// created while hammering all old pids). Run by run.sh (-DMS_DRC_LEDGER, drc+orc).

import { stop, ExitReason } from "std/actor";
import { exit } from "std/process";

actor Cell {
    buf: string;
    constructor() {
        let s = "g";
        for (let i = 0; i < 6; i = i + 1) { s = s + s; }
        this.buf = s;
    }
    ping(): int32 {
        return this.buf.length;
    }
}

function main(): void {
    const stale: int64[] = [];
    for (let n = 0; n < 20; n = n + 1) {
        const c = new Cell();
        const r = await c.ping();
        if (r !== 64) { exit(1); }
        stale.push(c.pid);
        stop(c.pid, ExitReason.Normal);
        stop(c.pid, ExitReason.Normal);
    }
    let spin = 0;
    for (let i = 0; i < 300000; i = i + 1) { spin = (spin + i) % 7; }
    for (const p of stale) {
        stop(p, ExitReason.Normal);
        stop(p, ExitReason.Killed);
    }
    let total = 0;
    for (let n = 0; n < 20; n = n + 1) {
        const c = new Cell();
        for (const p of stale) { stop(p, ExitReason.Killed); }
        const r = await c.ping();
        total = total + r;
        stop(c.pid, ExitReason.Normal);
    }
    if (total !== 1280) {
        console.log("actorStalePid FAIL total=" + total.toString());
        exit(1);
    }
    console.log("actorStalePid ok total=" + total.toString() + " spin=" + spin.toString());
}
main();
