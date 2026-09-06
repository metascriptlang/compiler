// Scenario: legitimate limitations of MS's 3-pass spirit. Cases where T
// cannot be bound from any source EXCEPT re-checking the lambda body —
// which the 3-pass design intentionally does not do (re-check would
// violate "set once in Pass 3, stable for downstream").
//
// These scenarios SHOULD produce a clear checker error, OR they should
// produce a lambda where the param is Unknown (not GenericParam). Either
// way: NO silent corruption, NO GenericParam leakage into nodeType.
//
//   applyN((x) => x*2, 4, 1)    // lambda first, no <T>, no concrete arg
//                                 to bind T from. T must come from lambda
//                                 body inference — MS doesn't do that.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

// Note: this is a "documented limitation" scenario. The behavior we want:
//   - Either checker emits a clear error
//   - Or the lambda param resolves to Unknown (not GenericParam)
//   - Crucially: NO GenericParam leakage that downstream silently propagates.
const SRC_LIMITATION = `
function applyN9<T>(f: (acc: T) => T, n: int32, init: T): T {
	let acc: T = init;
	let i: int32 = 0 as int32;
	while (i < n) {
		acc = f(acc);
		i = (i + (1 as int32)) as int32;
	}
	return acc;
}

function main9(): void {
	const factor: int32 = 3 as int32;
	const r = applyN9((x) => (x * factor) as int32, 4 as int32, 1 as int32);
}
`;

test "limitation: closure-first generic call — global invariant still holds (no silent corruption)" {
	const result = checkOnly(SRC_LIMITATION);
	// We accept EITHER:
	//   (a) checker errors (legitimate "can't infer T")
	//   (b) clean check + arrow param resolves to a non-GenericParam type
	// What we REJECT: silent corruption (no errors but GenericParam leaked).
	if (result.errors.length == 0) {
		const violations = checkNoGenericParamLeakage(result.program);
		if (violations.length > 0) {
			assert false, "limitation: silent corruption detected — checker emitted no errors but GenericParam leaked:\n" + formatViolations(violations);
		}
	}
	// If checker emitted errors, that's also acceptable (legitimate "cannot infer").
	assert true;
}
