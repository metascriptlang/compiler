// bug049 — test-block body with an unguarded raising call emits `goto BeforeRet_`
//          with no landing label (undeclared label at clang)
//
// Symptom:    Any downstream that test-compiles a module using std/serialize/json
//             or websocket failed at clang: `use of undeclared label 'BeforeRet_'`
//             on `if (msErr) goto BeforeRet_;` inside a __ms_test_N function.
//             Hidden because the compiler self-build is --release (no test blocks)
//             and the compiler battery never imports json.
//
// Root cause: the raise-propagation (a raising call with no enclosing try sets
//             beforeRetNeeded + emits `goto BeforeRet_`) was paired with the
//             `BeforeRet_:` label at 4 of the 5 proc-emission sites; the
//             test-block emitter (codegen/c/test.ms) drained stmts without ever
//             laying the label.
//
// Fix:        collapse the proc-body drain + label into one funnel
//             (context.ms emitProcBody) that every ordinary-proc site — including
//             the test-block emitter — goes through.
//
// Nim parity: Nim lays `BeforeRet_` in a single proc assembler (cgen.nim
//             genProcAux, `if beforeRetNeeded in p.flags`) that every proc drains
//             through, so the goto/label pair can't desync. We had split it into
//             hand-rolled sites; this returns to the single-funnel model.

function bug049MayRaise(x: int32): int32 {
    if (x < 0) { throw "neg"; }
    return x + 1;
}

test "bug049: no-try raising call in a test block compiles and runs" {
    const a = bug049MayRaise(1);
    assert a == 2;
}
