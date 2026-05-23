// Scenario: generic function that recursively calls itself with the same
// type parameter. This tests the 3-pass design's strength: Pass 1 makes
// the symbol visible before Pass 3 checks the body, so self-recursive
// generics work.
//
// Inside the generic body, `T` IS a legitimate GenericParam — invariant
// walker must NOT flag this (template scope exempt). The recursive call
// `f7<T>(...)` uses T (which IS GenericParam inside f7's own body).
//
// Outside the template, no leakage should occur.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_RECURSIVE = `
function f7<T>(x: T, n: int32): T {
	if (n <= 0) return x;
	return f7<T>(x, (n - (1 as int32)) as int32);
}

function main7(): void {
	const r: int32 = f7<int32>(42 as int32, 3 as int32);
}
`;

test "recursive-generic: no checker errors" {
	const result = checkOnly(SRC_RECURSIVE);
	assert result.errors.length === 0;
}

test "recursive-generic: global invariant — leakage exempted in template body, none outside" {
	const result = checkOnly(SRC_RECURSIVE);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
