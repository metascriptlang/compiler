// Scenario: generic constructor with closure arg. Tests the NewExpr path,
// which may have its own arg-check flow separate from checkCallExpr.
//
// If RED → Phase C must extend substitution to constructor paths.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_CTOR = `
class Holder<T> {
	value: T;
	transform: (x: T) => T;
	constructor(v: T, f: (x: T) => T) {
		this.value = v;
		this.transform = f;
	}
}

function main5(): void {
	const factor: int32 = 3 as int32;
	const h = new Holder<int32>(5 as int32, (x) => (x * factor) as int32);
}
`;

test "generic-constructor: no checker errors" {
	const result = checkOnly(SRC_CTOR);
	assert result.errors.length == 0;
}

test "generic-constructor: arrow has no GenericParam leakage" {
	const result = checkOnly(SRC_CTOR);
	const main_fn = findFnDecl(result.program, "main5");
	assert main_fn != null;
	const arrow = findFirstArrow(main_fn);
	assert arrow != null;
	assert arrow.nodeType != null;
	assert arrow.nodeType.typeChildren.length > 0;
	const k = arrow.nodeType.typeChildren[0].kind;
	assert k == TypeKind.Int32,
		"ctor substitution failed: arrow.typeChildren[0].kind = " + k.toString();
}

test "generic-constructor: global invariant — no GenericParam leakage" {
	const result = checkOnly(SRC_CTOR);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
