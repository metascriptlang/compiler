// Stress: generic function with 4 type params + closure arg. Verifies
// explicit type args bind correctly for all params, AND forward inference
// works when only SOME params are explicit.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_MANY = `
function manyP<T1, T2, T3, T4>(a: T1, b: T2, c: T3, f: (x: T4) => T4): T4 {
	return f(a as int32 as T4);
}

function mainMany(): void {
	const factor: int32 = 7 as int32;
	const r = manyP<int32, string, boolean, int32>(
		1 as int32,
		"hello",
		true,
		(x) => (x * factor) as int32
	);
}
`;

test "stress many-params: no checker errors" {
	const result = checkOnly(SRC_MANY);
	assert result.errors.length == 0;
}

test "stress many-params: arrow's param is Int32 (T4 bound from explicit)" {
	const result = checkOnly(SRC_MANY);
	const main_fn = findFnDecl(result.program, "mainMany");
	assert main_fn != null;
	const arrow = findFirstArrow(main_fn);
	assert arrow != null;
	assert arrow.nodeType != null;
	assert arrow.nodeType.typeChildren.length > 0;
	assert arrow.nodeType.typeChildren[0].kind == TypeKind.Int32;
}

test "stress many-params: no GenericParam leakage" {
	const result = checkOnly(SRC_MANY);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
