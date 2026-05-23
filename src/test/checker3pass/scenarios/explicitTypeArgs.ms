// Scenario: generic call with EXPLICIT type args + untyped closure arg
//
// BUG #2 repro at the checker level.
//
//   function applyN<T>(n: int32, init: T, f: (acc: T) => T): T { ... }
//   applyN<int32>(4, 1, (x) => x * factor as int32)
//                       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
//                       arrow's `x` is untyped — checker should
//                       inherit `int32` from the substituted formal,
//                       NOT GenericParam('T').
//
// Pre-Phase-A: this test RED — `x` gets GenericParam('T'), invariant
// walker catches it, downstream lambda lifting carries the leak into
// codegen, body silently dropped.
//
// Post-Phase-A: this test GREEN — explicit `<int32>` binding applied
// before arg-walk, arrow sees `(int32) => int32` as expected type,
// `x` typed as int32.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_BASIC = `
function applyN<T>(n: int32, init: T, f: (acc: T) => T): T {
	let acc: T = init;
	let i: int32 = 0 as int32;
	while (i < n) {
		acc = f(acc);
		i = (i + (1 as int32)) as int32;
	}
	return acc;
}

function main(): void {
	const factor: int32 = 3 as int32;
	const r = applyN<int32>(4 as int32, 1 as int32, (x) => (x * factor) as int32);
}
`;

test "BUG#2 repro: explicit type args + untyped closure — no checker errors" {
	const result = checkOnly(SRC_BASIC);
	assert result.errors.length === 0;
}

test "BUG#2 invariant: arrow inside main has no GenericParam leakage" {
	const result = checkOnly(SRC_BASIC);
	assert result.errors.length === 0;

	const main_fn = findFnDecl(result.program, "main");
	assert main_fn !== null, "main fn not found";

	const arrow = findFirstArrow(main_fn);
	assert arrow !== null, "arrow inside main not found";
	assert arrow.nodeType !== null, "arrow has null nodeType";

	// CRITICAL ASSERTION: arrow's first param type must be Int32 (substituted), NOT GenericParam.
	assert arrow.nodeType.typeChildren !== null, "arrow.nodeType.typeChildren is null";
	assert arrow.nodeType.typeChildren.length > 0, "arrow.nodeType.typeChildren is empty";

	const firstParamKind = arrow.nodeType.typeChildren[0].kind;
	if (firstParamKind === TypeKind.GenericParam) {
		const name = arrow.nodeType.typeChildren[0].typeName;
		assert false, "arrow.nodeType.typeChildren[0] is GenericParam('" + name + "') — should be Int32";
	}
	assert firstParamKind === TypeKind.Int32,
		"arrow.nodeType.typeChildren[0].kind = " + firstParamKind.toString() + " (expected Int32 = 10)";
}

test "BUG#2 global invariant: no GenericParam leakage outside templates" {
	const result = checkOnly(SRC_BASIC);
	assert result.errors.length === 0;

	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) {
		assert false, formatViolations(violations);
	}
	assert true;
}
