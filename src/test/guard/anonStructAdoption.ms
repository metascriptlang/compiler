// nim-guard: anonymous-literal adoption into a named value struct — every
// fit position, C and js identical
//
// INVARIANT (compat.ms isAnonStructAdoption + checkExprPass fitNode):
//   `const t = { a: 1, b: "x" }` freezes as an anonymous type; where it meets
//   a NAMED VALUE STRUCT whose field list matches EXACTLY, fitNode (single
//   funnel) re-constructs it member-wise as that struct. Positions covered:
//   call arg, var init, assignment, return, ternary branch, array element,
//   object field, generic call arg with contextual type (Result.ok(t) under
//   an expected Result<S,E>). A position that forgets is a backend split:
//   C rejects at clang while js runs the raw value.
//   Mirrors the reference's implicitConv/nkHiddenStdConv fit funnel and its
//   post-binding arg reconciliation (sigmatch); the adoption rule itself is
//   ours (the reference constructs objects nominally).
//   A struct crosses a by-value boundary as a COPY already, so re-constructing
//   member-wise adds no observable semantics — that is why this is safe here
//   and NOT for interface/class targets (see anonLiteralNamedStruct.ms).
//
// WHAT IT CATCHES: a fit-site refactor dropping adoption at one position, or
//   the member-wise copy losing a managed field's refcount (the string below
//   is heap-built, so a missing incref shows up as a double-destroy abort and
//   a missing decref as ledger imbalance).
//
// COVERED ELSEWHERE (previously misattributed to anon literals): a
//   context-free generic call (`const r = Result.ok(t)`) leaves E unbound —
//   that is the unbound-param check's territory (genericUnboundParam.ms),
//   independent of anon-ness: a fully annotated source failed identically.
//
// RED MEANS: one position stopped adopting (build error naming that line), or
//   the copy's DRC hooks drifted.
//
// GUARD-JS

struct GuardAdoptS { id: int32; buf: string; }
struct GuardAdoptW { inner: GuardAdoptS; }

const GUARD_PARTS: string[] = ["alpha", "beta", "gamma"];

function guardTake(s: GuardAdoptS): int32 { return s.buf.length; }

function guardMake(n: int32): GuardAdoptS {
    const made = { id: n, buf: "payload-" + GUARD_PARTS[n % 3] + "-tail" };
    return made;
}

function guardGive(n: int32): Result<GuardAdoptS, string> {
    const made = { id: n, buf: "payload-" + GUARD_PARTS[n % 3] + "-tail" };
    return Result.ok(made);
}

function main(): void {
    const t = { id: 7, buf: "payload-" + GUARD_PARTS[1] + "-tail" };
    const viaArg = guardTake(t);
    const viaInit: GuardAdoptS = t;
    let viaAssign: GuardAdoptS = { id: 0, buf: "seed" };
    viaAssign = t;
    const viaReturn = guardMake(2);
    const seed: GuardAdoptS = { id: 1, buf: "seed2" };
    const viaTernary: GuardAdoptS = viaArg > 0 ? t : seed;
    const viaArray: GuardAdoptS[] = [t];
    const viaField: GuardAdoptW = { inner: t };
    const viaGeneric = guardGive(1);

    let churn = 0;
    for (let i = 0; i < 5000; i += 1) {
        const c = { id: i % 3, buf: "payload-" + GUARD_PARTS[i % 3] + "-tail" };
        const copied: GuardAdoptS = c;
        churn = (churn + guardTake(copied)) % 1000;
    }

    console.log("arg=" + viaArg);
    console.log("init=" + viaInit.buf);
    console.log("assign=" + viaAssign.id);
    console.log("return=" + viaReturn.buf);
    console.log("ternary=" + viaTernary.id);
    console.log("array=" + viaArray[0].buf);
    console.log("field=" + viaField.inner.id);
    console.log("churn=" + churn);
    if (viaArg != 17) { throw "GUARD RED: arg length " + viaArg; }
    if (viaInit.buf != t.buf) { throw "GUARD RED: init buf " + viaInit.buf; }
    if (viaAssign.id != 7) { throw "GUARD RED: assign id " + viaAssign.id; }
    if (viaReturn.id != 2) { throw "GUARD RED: return id " + viaReturn.id; }
    if (viaTernary.id != 7) { throw "GUARD RED: ternary id " + viaTernary.id; }
    if (viaArray[0].buf != t.buf) { throw "GUARD RED: array buf " + viaArray[0].buf; }
    if (viaField.inner.id != 7) { throw "GUARD RED: field id " + viaField.inner.id; }
    if (!viaGeneric.ok) { throw "GUARD RED: generic not ok"; }
    if (viaGeneric.ok) {
        if (viaGeneric.value.id != 1) { throw "GUARD RED: generic id " + viaGeneric.value.id; }
        if (viaGeneric.value.buf.length != 17) { throw "GUARD RED: generic buf " + viaGeneric.value.buf; }
    }
    console.log("GUARD-OK");
}
main();
