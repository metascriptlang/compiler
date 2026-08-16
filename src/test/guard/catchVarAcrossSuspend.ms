// nim-guard: catch variable bound across an await suspend (reference :curExc)
//
// INVARIANT (reference closureiters :curExc): when a try body suspends on
//   `await` and then raises, the caught exception is carried across the
//   state-machine boundary in an env field ($curExc) that the catch state
//   reads. The env that owns $curExc must be finalized exactly once — no leak
//   (env alloc>destroy) and no double-free (DOUBLE-DESTROY) from the added carry.
//
// WHAT IT CATCHES:
//   - a full revert to the pre-fix state (per-state local / no carry) — the
//     catch var goes undeclared and the probe FAILS TO BUILD (red at build);
//   - a drift in generatorLower.splitTryCatch / buildExcRouting that leaks or
//     double-frees the $curExc-carrying env.
//
// NOT asserted here: the exception object (Error) itself leaks under both sync
//   and async catch today (pre-existing, tracked separately as the bare-catch /
//   catch-body discard-decref slice) — this guard scopes only to the carry env.
//
// RED MEANS: catch-var-across-suspend drifted from the reference :curExc model.
//   Run /trace-nim on the exception carry (generatorLower $curExc).
//
// GUARD-BALANCE dollarEnv_work_shared_

async function raiser(i: int32): Promise<int32> { return i; }

async function work(i: int32): Promise<int32> {
    try {
        const v = await raiser(i);
        if (v >= 0) throw new Error("boom");
        return v;
    } catch (e) {
        return e.message.length;
    }
}

function main(): void {
    let acc = 0;
    for (let n = 0; n < 50; n = n + 1) { acc = acc + waitFor(work(n)); }
    console.log(acc.toString());
}

main();
