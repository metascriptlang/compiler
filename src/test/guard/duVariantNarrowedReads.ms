// Guard: discriminated-union narrowing must route every field read through
// the ACTIVE variant. Un-narrowed reads of variant-specific fields are
// rejected at check time (pinned in checkPass "string DU subset field outside
// if is rejected"); this guard pins the runtime side — if/match/chained-member
// narrowing must return the active variant's value, never reinterpreted bytes.
// GUARD-JS: narrowing is checker-level; both backends must agree.

interface RectD { r: int32; w: int32; }
interface CircD { rad: int32; }
type Shape = { kind: "rect", rect: RectD } | { kind: "circ", circ: CircD };

interface Box { s: Shape; }

function pickIf(m: Shape): int32 {
    if (m.kind === "circ") {
        return m.circ.rad;
    }
    return m.rect.w;
}

function pickMatch(m: Shape): int32 {
    return match (m.kind) {
        "circ" => m.circ.rad,
        "rect" => m.rect.w,
    };
}

function pickChained(b: Box): int32 {
    if (b.s.kind === "circ") {
        return b.s.circ.rad;
    }
    return b.s.rect.w;
}

function pickExcluded(m: Shape): int32 {
    if (m.kind !== "circ") {
        return m.rect.w;
    }
    return m.circ.rad;
}

function main(): int32 {
    const circ: Shape = { kind: "circ", circ: { rad: 9 } };
    const rect: Shape = { kind: "rect", rect: { r: 3, w: 5 } };
    const box: Box = { s: { kind: "rect", rect: { r: 3, w: 5 } } };

    const cases: int32[] = [
        pickIf(circ), pickIf(rect),
        pickMatch(circ), pickMatch(rect),
        pickChained(box),
        pickExcluded(circ), pickExcluded(rect),
    ];
    const want: int32[] = [9, 5, 9, 5, 5, 9, 5];

    let rc: int32 = 0;
    for (let i: int32 = 0; i < cases.length; i += 1) {
        if (cases[i] !== want[i]) {
            console.log(`BAD[${i}]=${cases[i]} want=${want[i]}`);
            rc = 1;
        }
    }
    if (rc === 0) { console.log("GUARD-OK duVariantNarrowedReads"); }
    return rc;
}

const rc = main();
if (rc !== 0) { process.exit(rc); }
