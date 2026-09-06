// Scenario: generic call WITHOUT explicit type args — T inferred from
// concrete leading args, closure as trailing arg should inherit substituted
// type.
//
//   function applyN<T>(n: int32, init: T, f: (acc: T) => T): T { ... }
//   applyN(4, 1, (x) => x * factor as int32)
//          ^^^   ^    ^^^^^^^^^^^^^^^^^^^^^^^
//        int32  int32  arrow inherits T=int32 forward from arg[1]
//
// Status check:
//   Phase A: fixed only EXPLICIT case → this scenario likely RED
//   Phase D (forward inference): would fix this — needs in-loop binding
//     accumulation OR pre-arg-walk forward-from-concrete-slots pass.
//
// Outcome of this test signals whether Phase D is needed.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFirstArrow, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_INFERRED = `
function applyN2<T>(n: int32, init: T, f: (acc: T) => T): T {
	let acc: T = init;
	let i: int32 = 0 as int32;
	while (i < n) {
		acc = f(acc);
		i = (i + (1 as int32)) as int32;
	}
	return acc;
}

function main2(): void {
	const factor: int32 = 3 as int32;
	const r = applyN2(4 as int32, 1 as int32, (x) => (x * factor) as int32);
}
`;

test "inferred-from-args: no checker errors" {
	const result = checkOnly(SRC_INFERRED);
	assert result.errors.length == 0;
}

test "inferred-from-args: arrow's first param should be Int32 (forward-inferred)" {
	const result = checkOnly(SRC_INFERRED);
	const main_fn = findFnDecl(result.program, "main2");
	assert main_fn != null;
	const arrow = findFirstArrow(main_fn);
	assert arrow != null;
	assert arrow.nodeType != null;
	assert arrow.nodeType.typeChildren.length > 0;
	assert arrow.nodeType.typeChildren[0].kind == TypeKind.Int32,
		"forward-from-args inference failed: arrow.typeChildren[0].kind = " + arrow.nodeType.typeChildren[0].kind.toString();
}

test "inferred-from-args: global invariant — no GenericParam leakage" {
	const result = checkOnly(SRC_INFERRED);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}
