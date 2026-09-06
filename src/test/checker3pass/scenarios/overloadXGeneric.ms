// Scenario: function overloading + generics + closure. The overloaded
// generic path goes through resolveOverloadCall (line 2955 in
// checkExprPass.ms), a DIFFERENT entry point than the non-overload
// arg-walk where Phase A applied substitution.
//
// If RED → Phase C must extend substitution to resolveOverloadCall too.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

// Simple overload set: one taking int, one taking string. Then a generic
// variant with a closure. The user picks the generic via explicit type arg.
const SRC_OVERLOAD = `
function ov8(x: int32): int32 { return x; }
function ov8(x: string): string { return x; }
function ov8<T>(x: T, f: (v: T) => T): T { return f(x); }

function main8(): void {
	const factor: int32 = 2 as int32;
	const r = ov8<int32>(10 as int32, (x) => (x * factor) as int32);
}
`;

test "overload-x-generic: no checker errors" {
	const result = checkOnly(SRC_OVERLOAD);
	assert result.errors.length == 0;
}

test "overload-x-generic: arrow has no GenericParam leakage" {
	const result = checkOnly(SRC_OVERLOAD);
	const main_fn = findFnDecl(result.program, "main8");
	assert main_fn != null;
	const arrow = findFirstArrow(main_fn);
	assert arrow != null;
	assert arrow.nodeType != null;
	assert arrow.nodeType.typeChildren.length > 0;
	const k = arrow.nodeType.typeChildren[0].kind;
	assert k == TypeKind.Int32,
		"overload+generic substitution failed: arrow.typeChildren[0].kind = " + k.toString();
}

test "overload-x-generic: global invariant — no GenericParam leakage" {
	const result = checkOnly(SRC_OVERLOAD);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
