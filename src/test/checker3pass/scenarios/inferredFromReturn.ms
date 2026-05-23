// Scenario: generic call where T inferred BACKWARD from caller's expected
// return type. This is Source 2 (backward inference) — already exists in
// the checker pre-Phase-A, so this scenario should be GREEN as a sanity
// check.
//
//   function pick<T>(v: T): T { return v; }
//   const r: int32 = pick(42);
//                    ^^^
//                    expected type int32 → T=int32 → arg `42` typed as int32

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_BACKWARD = `
function pick3<T>(v: T): T { return v; }

function main3(): void {
	const r: int32 = pick3(42 as int32);
}
`;

test "inferred-from-return: no checker errors" {
	const result = checkOnly(SRC_BACKWARD);
	assert result.errors.length === 0;
}

test "inferred-from-return: global invariant — no GenericParam leakage" {
	const result = checkOnly(SRC_BACKWARD);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
