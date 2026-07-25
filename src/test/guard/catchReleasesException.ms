// nim-guard: every catch handler releases the caught exception's sole reference
// exactly once — for a bare `catch {}` (no binding), an empty catch, AND an async
// catch whose handler never reads the bound variable.
//
// INVARIANT (reference exception RC, single-slot adaptation): the exception on
//   msCurrException carries exactly ONE reference; a handler consumes it once.
//   - genTryGoto emits popCurrentException() after EVERY handler (bare or named) —
//     the single free. MS bare `catch {}` has no owning catch-var, so it releases
//     via msDiscardCurrentException (decref+null); an empty catch must swallow too.
//   - closureiters binds :curExc via nkFastAsgn (NO incref). MS async carries the
//     exception in the $curExc env field, which must be typed as the exception type
//     (DRC-owned) EVEN when the handler ignores the var, and acquired by MOVE.
//
// WHAT IT CATCHES:
//   - bare/empty sync catch reverts to msClearException (null only, no decref) →
//     the Error leaks (alloc>destroy).
//   - async $curExc reverts to void* (untyped when the catch var is unused) → the
//     env field has no destructor hook → the Error leaks every iteration.
//   - async $curExc store reverts to COPY (msIncref) → over-owns → leak.
//
// RED MEANS: a catch path stopped releasing the caught Error — run /trace-nim on
//   the exception-consume point (msClearException / msDiscardCurrentException /
//   $curExc in generatorLower.buildExcRouting).
//
// GUARD-BALANCE Error

function boomSync(): void { throw new Error("syncBoom"); }
async function boomAsync(): Promise<int32> { throw new Error("asyncBoom"); }

// bare catch (no var) + empty catch, in a loop → many Errors, each swallowed.
function syncBareLoop(): int32 {
    let n = 0;
    let i = 0;
    while (i < 8) {
        try { boomSync(); } catch { n = n + 1; }
        try { boomSync(); } catch { }
        i = i + 1;
    }
    return n;
}

// async catch whose handler NEVER reads `e` → $curExc must still be DRC-owned.
async function asyncUnusedVar(): Promise<int32> {
    let n = 0;
    let i = 0;
    while (i < 8) {
        try { const x = await boomAsync(); } catch (e) { n = n + 1; }
        i = i + 1;
    }
    return n;
}

function main(): int32 {
    const a = syncBareLoop();
    const b = waitFor(asyncUnusedVar());
    if (a !== 8 || b !== 8) {
        console.log("GUARD-FAIL a=" + a.toString() + " b=" + b.toString());
        return 1;
    }
    console.log("ok");
    return 0;
}
