// nim-guard: an exception raised inside an ASYNC catch body propagates to the
// awaiter as the SAME live object — real message, exactly one release.
//
// INVARIANT (reference raise protocol, single-slot adaptation):
//   - closureiters wrapIntoTryExcept re-raises :curExc — the slot the routing
//     just stored into — never a local the store already invalidated. The
//     terminal (no in-function landing) must hand the caller a LIVE reference.
//   - injectdestructors pRaiseStmt treats the raise argument as a sink: an
//     owned-local source is moved (zeroed), a non-movable source (env field)
//     is copy-temp'd (pRaiseStmt tmp = copy; raise tmp). Either way the raise
//     machinery owns exactly one reference and no second live pointer remains.
//
// WHAT IT CATCHES:
//   - terminal re-raise reads the wasMoved-nulled $excCaught → msFutureFail(fut,
//     NULL) → awaiter sees synthesized "noproc" instead of the real message.
//   - rethrow aliases the env-owned $curExc without move/copy → two owners of
//     one ref → DOUBLE-DESTROY of Error at env death (ledger aborts).
//
// RED MEANS: the async raise path drifted — run /trace-nim on the terminal
//   rethrow in buildExcRouting (generatorLower.ms) and the ThrowStmt arm of
//   analyzer/inject.ms.
//
// GUARD-BALANCE Error

async function boom(): Promise<int32> { throw new Error("deep"); }

// catch builds a NEW Error from the caught one and throws it out of the fn.
async function wrapFresh(): Promise<int32> {
    try { return await boom(); }
    catch (e) { throw new Error(`wrapped:${e.message}`); }
}

// catch re-raises the SAME Error object out of the fn.
async function rethrow(): Promise<int32> {
    try { return await boom(); }
    catch (e) { throw e; }
}

async function run(): Promise<int32> {
    let bad = 0;
    for (let i = 0; i < 8; i += 1) {
        try { const v = await wrapFresh(); bad += 1; }
        catch (e2) {
            if (e2.message != "wrapped:deep") {
                console.log(`GUARD-FAIL wrap got:${e2.message}`);
                bad += 1;
            }
        }
        try { const v2 = await rethrow(); bad += 1; }
        catch (e3) {
            if (e3.message != "deep") {
                console.log(`GUARD-FAIL rethrow got:${e3.message}`);
                bad += 1;
            }
        }
    }
    return bad;
}

// Single-shot first: with few live allocations the slab cannot mask a dangling
// env->$curExc decref by slot reuse, so the DOUBLE-DESTROY channel actually
// fires (a looped body balances the ledger even while corrupting).
async function single(): Promise<int32> {
    let bad = 0;
    try { const v = await rethrow(); bad += 1; }
    catch (e) { if (e.message != "deep") bad += 1; }
    try { const v = await wrapFresh(); bad += 1; }
    catch (e) { if (e.message != "wrapped:deep") bad += 1; }
    return bad;
}

function main(): int32 {
    const badSingle = waitFor(single());
    const bad = waitFor(run());
    if (badSingle != 0 || bad != 0) return 1;
    console.log("ok");
    return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
