// A @comptime block runs with the checker context of the module in scope, so
// the typed queries answer inside it exactly as they do inside a macro body:
// bindSym finds a class declared in the module and getTypeImpl renders it.
//
// A red guard means the block evaluates without the expansion context and
// every query silently answers null.

import { bindSym, getTypeImpl, getImpl, typeKind, TypeKind, NodeKind } from "std/meta";

class Later {
	a: int32 = 1;
	b: string = "x";
}

const IMPL_KIND: int32 = @comptime {
	const t = getTypeImpl(bindSym("Later"));
	return t == null ? -1 : (typeKind(t) as int32);
};

const FIELDS: int32 = @comptime {
	const d = getImpl(bindSym("Later"));
	return d == null ? -1 : d.classBody.length;
};

function expect(actual: string, want: string, name: string): int32 {
	if (actual != want) {
		console.log(`GUARD-FAIL ${name}: got ${actual}, want ${want}`);
		return 1;
	}
	return 0;
}

function main(): int32 {
	let rc: int32 = 0;
	rc += expect(`${IMPL_KIND}`, `${TypeKind.Struct as int32}`, "comptimeGetTypeImpl");
	rc += expect(`${FIELDS}`, "2", "comptimeGetImpl");
	if (rc == 0) { console.log("GUARD-OK comptimeTypedQuery"); }
	return rc;
}

const rc = main();
if (rc != 0) { process.exit(rc); }
