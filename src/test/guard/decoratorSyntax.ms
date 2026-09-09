// GUARD-JS
// The decorator syntax surface: a dotted name resolved through a namespace
// import, a factory call spelled bare and namespaced on fields, and `export`
// written before the decorator. All three reach the same apply pass.
//
// A red guard means the parser or the decorator name resolution drifted.

import * as lib from "./fixtures/decoratorLib";
import { markSeen, seenCount, plusOne } from "./fixtures/decoratorLib";

@lib.tag
class Namespaced {
	@plusOne() n: int32 = 1;
	@lib.plusOne() m: int32 = 10;
}

export @lib.touch class ExportedFirst {
	v: int32 = 3;
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
	const a = new Namespaced();
	rc += expect(`${a.n}`, "2", "bareFactory");
	rc += expect(`${a.m}`, "11", "dottedFactory");
	rc += expect(`${seenCount()}`, "1", "dottedClassInitializer");
	const b = new ExportedFirst();
	rc += expect(`${b.v}`, "3", "exportBeforeDecorator");
	if (rc == 0) { console.log("GUARD-OK decoratorSyntax"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
