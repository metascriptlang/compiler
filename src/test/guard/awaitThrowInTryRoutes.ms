// nim-guard: an await that RAISES must re-raise into the enclosing catch — even
// when the awaited future is void and/or the await is the LAST statement in the try.
//
// INVARIANT (reference await + future read): every await, including Future[void],
//   performs read() on resume, and read() raises fut.error UNCONDITIONALLY (only
//   the value-extract is `when T isnot void`). The read is a statement INSIDE the
//   try, so its resume state must sit in the try's exception routing and reach the
//   LOCAL catch — not propagate out.
//
// WHAT IT CATCHES:
//   - full pre-fix compiler MISCOMPILES this shape (catch-var of a try whose last
//     stmt is an await) → emits C referencing an undeclared catch var → build red.
//   - drop only the void-await re-raise (asyncBridge msFutureCheckErr) → a void
//     await swallows the error → catch never fires → caught stays 0 → nonzero exit.
//   - drop only the in-try resume state (generatorLower.splitTryCatch tryExit) → a
//     trailing await's resume routes to terminal → local catch skipped → nonzero exit.
//
// RED MEANS: async-await failure propagation drifted from the reference await/read
//   model. Run /trace-nim on the await resume (asyncBridge / generatorLower).
//
// GUARD-BALANCE dollarEnv_voidCase_shared_
// GUARD-BALANCE dollarEnv_valCase_shared_
// GUARD-BALANCE Error

async function throwsVoid(): Promise<void> { throw new Error("deep"); }
async function throwsVal(): Promise<int32> { throw new Error("val12"); }

// void await, LAST stmt in try → exercises void-read (#1) + trailing routing (#2)
async function voidCase(): Promise<int32> {
    let caught = 0;
    try { await throwsVoid(); }
    catch (e) { caught = e.message.length; }
    return caught;
}

// value await, LAST stmt in try → exercises trailing routing (#2) on the value path
async function valCase(): Promise<int32> {
    let caught = 0;
    try { const x = await throwsVal(); }
    catch (e) { caught = e.message.length; }
    return caught;
}

function main(): int32 {
    const a = waitFor(voidCase());
    const b = waitFor(valCase());
    if (a !== 4 || b !== 5) {
        console.log("GUARD-FAIL a=" + a.toString() + " b=" + b.toString());
        return 1;
    }
    console.log("ok");
    return 0;
}

const guardRc = main();
if (guardRc !== 0) process.exit(guardRc);
