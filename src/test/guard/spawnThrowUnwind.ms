// nim-guard: exception unwind through a live spawn scope — no double-free / no leak
//
// INVARIANT (Nim/PARALOCK): unwinding an exception through a scope that owns
//   spawn closure envs must finalize each env exactly once — the error path
//   must run the SAME scope-exit / completion destroys as the success path,
//   no more, no less. Nim ARC injects the same `=destroy` set on the raising
//   control-flow edge (injectdestructors over the exception CFG).
// PARALOCK: E120 (spawn child throws → siblings cancelled, first exception
//   propagates out of await) + E124 (exception between spawn and await → pending
//   children's handles dropped during unwind) + E140 (env is DRC-counted).
//
// WHAT IT CATCHES: a refactor of the worker ERROR-completion / cancel-unwind
//   path that double-releases (or skips) the closure env — invisible to the
//   success-path guard (spawnEnvHeapCapture) because it only fires when a child
//   throws. Proven red by injecting a double env-release on the worker error
//   branch (thread.h): this guard RED, the success guard GREEN.
//
// RED MEANS: the exception/cancel path corrupts closure-env lifecycle. Run
//   /trace-nim on the type named in the DOUBLE-DESTROY line; check the worker
//   error branch + the scope-exit destroys on the raising CFG edge.
//
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc). Heap capture
// (cc) + loop-local capture (j); every child throws so every run exercises the
// error-completion + unwind path; high iteration for determinism.

interface Job { name: string; }

function work(cc: string, jobs: Job[]): int32 {
    const futures: Promise<int32>[] = [];
    for (const j of jobs) {
        futures.push(spawn(() => {
            let r = j.name.length + cc.length;
            if (r > 0) { throw "boom"; }
            return r;
        }));
    }
    let total = 0;
    for (const f of futures) total = total + waitFor(f);
    return total;
}

function main(): void {
    let s = "x"; s = s + "y";
    let acc = 0;
    for (let n = 0; n < 500; n = n + 1) {
        const jobs: Job[] = [{name:"aa"},{name:"bb"},{name:"cc"},{name:"dd"}];
        try { acc = acc + work(s, jobs); } catch (e) { acc = acc + 1; }
    }
    console.log(acc);
}

main();
