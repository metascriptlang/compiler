// GUARD-JS
// Break/continue jump targets across lowered dispatch (switch/match).
//
// Pins the contract fixed 2026-09-03 (labeled-break port of Nim's
// transformLoopBody/ccgstmts genBreakStmt model):
//   1. `break` in a match arm targets the enclosing LOOP (C and JS).
//   2. `continue` in a match arm skips the iteration (was already true by
//      accident of C semantics; now pinned).
//   3. `break` in a user switch case (string discriminant, erased to if-chain
//      inside a labeled wrapper) exits the SWITCH, not the loop.
//   4. A conditional mid-case `break` in an ordinal switch skips the rest of
//      the case only.
//   5. `break` in a switch outside any loop is legal (TS parity).
// A red guard means jumpRetarget/switchLower/codegen label plumbing drifted.

function matchArmBreakForOf(): int32 {
    let sum: int32 = 0;
    for (const x of [1, 2, 3, 4, 5]) {
        match (x) {
            3 => { break; },
            _ => {},
        };
        sum = sum + x;
    }
    return sum;
}

function matchArmBreakWhile(): int32 {
    let sum: int32 = 0;
    let i: int32 = 0;
    while (i < 5) {
        const x = i + 1;
        match (x) {
            3 => { break; },
            _ => {},
        };
        sum = sum + x;
        i = i + 1;
    }
    return sum;
}

function matchArmContinue(): int32 {
    let sum: int32 = 0;
    for (const x of [1, 2, 3, 4, 5]) {
        match (x) {
            3 => { continue; },
            _ => {},
        };
        sum = sum + x;
    }
    return sum;
}

function nestedLoopBreak(): string {
    let inner: int32 = 0;
    for (const a of [1, 2]) {
        for (const b of [10, 20, 30]) {
            match (b) {
                20 => { break; },
                _ => {},
            };
            inner = inner + b;
        }
    }
    return `${inner}`;
}

function stringSwitchBreakStaysInLoop(): string {
    let sum: int32 = 0;
    let hits: string = "";
    for (const x of [1, 2, 3, 4, 5]) {
        const k = x === 3 ? "stop" : "go";
        switch (k) {
            case "stop":
                hits = hits + "S";
                break;
            default:
                hits = hits + "g";
        }
        sum = sum + x;
    }
    return `${sum},${hits}`;
}

function ordinalSwitchMidCaseBreak(): string {
    let log: string = "";
    for (const x of [1, 2, 3, 4, 5]) {
        switch (x) {
            case 3:
                log = log + "a";
                if (x > 0) { break; }
                log = log + "b";
            default:
                log = log + ".";
        }
    }
    return log;
}

function switchOutsideLoop(): string {
    const x: int32 = 2;
    let log: string = "";
    switch (x) {
        case 2:
            log = log + "two";
            break;
        default:
            log = log + "other";
    }
    return log;
}

function expect(actual: string, want: string, name: string): int32 {
    if (actual !== want) {
        console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
        return 1;
    }
    return 0;
}

function main(): int32 {
    let rc = expect(`${matchArmBreakForOf()}`, "3", "matchArmBreakForOf");
    rc += expect(`${matchArmBreakWhile()}`, "3", "matchArmBreakWhile");
    rc += expect(`${matchArmContinue()}`, "12", "matchArmContinue");
    rc += expect(nestedLoopBreak(), "20", "nestedLoopBreak");
    rc += expect(stringSwitchBreakStaysInLoop(), "15,ggSgg", "stringSwitchBreakStaysInLoop");
    rc += expect(ordinalSwitchMidCaseBreak(), "..a..", "ordinalSwitchMidCaseBreak");
    rc += expect(switchOutsideLoop(), "two", "switchOutsideLoop");
    if (rc === 0) { console.log("GUARD-OK breakJumpTargets"); }
    return rc;
}

const rc = main();
if (rc !== 0) { process.exit(rc); }
