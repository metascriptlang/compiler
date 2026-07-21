// nim-guard: spawn closure-env heap capture — destroy-once-on-last-ref
//
// INVARIANT (Nim): a type's destroy hook runs exactly once, only on the
//   last-ref decref. Nim invokes `=destroy` solely via nimDecRefIsLast-gated
//   rawDispose; the ARC dispose protocol never finalizes a live object.
// NIM-REF: "DRC scope cleanup" row + the completion-queue deferred-release
//   notes. PARALOCK E140: a spawn closure env is DRC-counted — "dec on
//   completion" must be a real decref (free only if last), never an
//   unconditional destroy.
//
// WHAT IT CATCHES: regression c528e2a hoisted destroyFn OUT of the last-ref
//   guard in the kind=-3 completion drain. A per-iteration env still owned by
//   its scope local was finalized twice → the captured heap string was
//   double-freed (~30% of runs, SIGABRT). Fixed 0ecf8c5.
//
// RED MEANS: some decref/destroy path finalized an object that still had an
//   owner (double-destroy) — a drift from the Nim last-ref dispose model.
//   Run /trace-nim on the type named in the "DOUBLE-DESTROY of <type>" line.
//
// Trigger needs BOTH a per-iteration loop-local capture (j via for..of) AND a
// shared loop-invariant HEAP string (cc; a literal would make the double free
// a no-op). High iteration makes the finalize-while-owned window deterministic.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

interface Job { name: string; }

function work(cc: string, jobs: Job[]): int32 {
    const futures: Promise<int32>[] = [];
    for (const j of jobs) {
        futures.push(spawn(() => {
            let r = j.name.length + cc.length;
            if (r < 0) { r = j.name.length + cc.length; }
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
    for (let n = 0; n < 2000; n = n + 1) {
        const jobs: Job[] = [{name:"aa"},{name:"bb"},{name:"cc"},{name:"dd"}];
        acc = acc + work(s, jobs);
    }
    console.log(acc);
}
