// GUARD-JS
// A decorator on a static field must keep the field on the class.
//
// Measured 2026-09-08: `@tag static sf: int32 = 7` made `A.sf` a type error
// ("Property 'sf' does not exist") — the static member was collected only when
// it was a bare property declaration. The undecorated control compiled.
// A red guard means a decorated static field disappears from its class again.

import { Node } from "std/meta";

function tag(value: Node): void {}

class Registry {
    @tag static limit: int32 = 7;
    @tag static name: string = "reg";
    static plain: int32 = 2;

    static total(): int32 { return Registry.limit + Registry.plain; }
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
    rc += expect(`${Registry.limit}`, "7", "decoratedStaticInt");
    rc += expect(Registry.name, "reg", "decoratedStaticString");
    rc += expect(`${Registry.total()}`, "9", "totalWithPlainStatic");
    if (rc == 0) { console.log("GUARD-OK decoratedStaticField"); }
    return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
