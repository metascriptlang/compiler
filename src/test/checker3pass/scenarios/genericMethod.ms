// Scenario: generic METHOD call with closure arg. Tests a different
// CHECKER ENTRY POINT than checkCallExpr's Identifier-callee path —
// specifically the MemberExpr-callee path (`obj.method<U>(...)`).
//
// If Phase A's fix at checkCallExpr line 2218 only covered the Identifier
// path, this scenario may still RED — signaling Phase C must extend
// substitution to method-call paths too.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

// Use std/Array's generic `map<U>` method shape via a user class to avoid
// platform-specific stdlib variance.
const SRC_METHOD = `
class Cell<T> {
	value: T;
	transform<U>(f: (x: T) => U): U {
		return f(this.value);
	}
}

function main4(): void {
	const c = new Cell<int32>(5 as int32);
	const factor: int32 = 2 as int32;
	const result: int32 = c.transform<int32>((x) => (x * factor) as int32);
}
`;

test "generic-method: no checker errors" {
	const result = checkOnly(SRC_METHOD);
	assert result.errors.length == 0;
}

test "generic-method: arrow inside main4 has no GenericParam leakage" {
	const result = checkOnly(SRC_METHOD);
	const main_fn = findFnDecl(result.program, "main4");
	assert main_fn != null;
	const arrow = findFirstArrow(main_fn);
	assert arrow != null;
	assert arrow.nodeType != null;
	assert arrow.nodeType.typeChildren.length > 0;
	const k = arrow.nodeType.typeChildren[0].kind;
	assert k == TypeKind.Int32,
		"method-call substitution failed: arrow.typeChildren[0].kind = " + k.toString();
}

test "generic-method: global invariant — no GenericParam leakage" {
	const result = checkOnly(SRC_METHOD);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) {
		console.log("[generic-method violations]");
		console.log(formatViolations(violations));
	}
	assert violations.length == 0;
}
