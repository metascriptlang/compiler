// GUARD-JS
// A class decorator may return a class declaration and the compiler collects
// the returned one: the pass runs before the class symbol exists, so a
// replacement needs no re-synchronisation of an already-shaped symbol.
//
// A red guard means class-level replacement regressed, or the rewritten
// statement stopped being collected.

import { Node, NodeKind, ClassDecoratorContext } from "std/meta";

macro withExtra(value: Node, context: ClassDecoratorContext): Node {
	value.classBody.push({
		kind: NodeKind.PropertyDecl, line: value.line, column: value.column,
		propName: "extra", propType: "int32", propIsStatic: false, propIsReadonly: false,
		propVisibility: "public",
		propInitializer: { kind: NodeKind.NumberLiteral, line: value.line, column: value.column, value: 42, isFloat: false },
	});
	return value;
}

@withExtra
class Widget {
	base: int32 = 1;
}

export @withExtra class Exported {
	tag: int32 = 7;
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
	const w = new Widget();
	rc += expect(`${w.base}`, "1", "originalFieldKept");
	rc += expect(`${w.extra}`, "42", "replacementFieldPresent");
	const e = new Exported();
	rc += expect(`${e.tag}`, "7", "exportedOriginalField");
	rc += expect(`${e.extra}`, "42", "exportedReplacementField");
	if (rc == 0) { console.log("GUARD-OK decoratorClassReplace"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
