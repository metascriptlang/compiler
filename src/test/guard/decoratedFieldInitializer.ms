// GUARD-JS
// A decorator on an instance field must keep the field's initializer.
//
// Measured 2026-09-08: `@tag x: int32 = 5` read back 0 — `fieldInitStatements`
// only matched bare property declarations, so the decorated field's initializer
// silently never reached the constructor. Nothing failed to build.
// A red guard means a decorated field's initializer is dropped again.

import { Node } from "std/meta";

function tag(value: Node): void {}

class Counter {
    @tag x: int32 = 5;
    @tag label: string = "start";
    y: int32 = 9;

    sum(): int32 { return this.x + this.y; }
}

function expect(actual: string, want: string, name: string): int32 {
    if (actual != want) {
        console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
        return 1;
    }
    return 0;
}

function main(): int32 {
    let rc: int32 = 0;
    const c = new Counter();
    rc += expect(`${c.x}`, "5", "decoratedInt");
    rc += expect(c.label, "start", "decoratedString");
    rc += expect(`${c.sum()}`, "14", "sumWithPlainField");
    if (rc == 0) { console.log("GUARD-OK decoratedFieldInitializer"); }
    return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
