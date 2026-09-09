// GUARD-BALANCE Holder
// GUARD-JS
// A decorator on a class must not change the class's lifecycle codegen.
//
// Measured 2026-09-08: `@tag class Holder {}` + `new Holder()` failed to link
// (`_Holder_init` undefined) because `lowerCtorInit` never unwrapped the
// decorator node, and the same wrapper also dropped the destructor and the
// TypeInfo definition while `TypeInfo.destroyFn` kept referencing them.
// A red guard means a decorated class lost its constructor, destructor or
// TypeInfo again — the decorator wrapper leaked past the pass that applies it.

import { Node } from "std/meta";

function tag(value: Node): void {}

@tag
class Holder {
    name: string;
    tag: string;
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
    const h = new Holder();
    h.name = "alpha";
    h.tag = "beta";
    rc += expect(h.name, "alpha", "fieldName");
    rc += expect(h.tag, "beta", "fieldTag");
    const holders: Holder[] = [];
    for (let i = 0; i < 3; i += 1) {
        const x = new Holder();
        x.name = `n${i}`;
        x.tag = `t${i}`;
        holders.push(x);
    }
    rc += expect(`${holders.length}`, "3", "holders");
    rc += expect(holders[2].tag, "t2", "lastTag");
    if (rc == 0) { console.log("GUARD-OK decoratedClassLifecycle"); }
    return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
