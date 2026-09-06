// Scenario: nested generic calls — bindings need to flow through multiple
// call expression layers without losing substitution.
//
//   const r = outer<int32>(inner<int32>((x) => x * 2 as int32))
//
// Each layer's substitution must be independent. The innermost arrow
// should see Int32 even though it's two layers deep.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_NESTED = `
function inner6<T>(f: (x: T) => T): (x: T) => T {
	return f;
}

function outer6<U>(g: (x: U) => U): U {
	const seed: U = (1 as int32) as U;
	return g(seed);
}

function main6(): void {
	const factor: int32 = 4 as int32;
	const r = outer6<int32>(inner6<int32>((x) => (x * factor) as int32));
}
`;

test "nested-generic: no checker errors" {
	const result = checkOnly(SRC_NESTED);
	assert result.errors.length == 0;
}

test "nested-generic: innermost arrow has no GenericParam leakage" {
	const result = checkOnly(SRC_NESTED);
	const main_fn = findFnDecl(result.program, "main6");
	assert main_fn != null;
	const arrow = findFirstArrow(main_fn);
	assert arrow != null;
	assert arrow.nodeType != null;
	assert arrow.nodeType.typeChildren.length > 0;
	const k = arrow.nodeType.typeChildren[0].kind;
	assert k == TypeKind.Int32,
		"nested generic substitution failed: arrow.typeChildren[0].kind = " + k.toString();
}

test "nested-generic: global invariant — no GenericParam leakage" {
	const result = checkOnly(SRC_NESTED);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
