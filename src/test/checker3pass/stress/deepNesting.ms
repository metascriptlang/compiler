// Stress: 5-level deep nested generic calls with closures at multiple
// levels. Verifies bindings substitute correctly through each layer
// without contamination between layers.
//
// Each generic call site is independent — explicit `<int32>` at one layer
// must not leak into another. Closures at any level must see concrete types.

import { TypeKind } from "../../../ast/node";
import { checkOnly, findFnDecl } from "../helpers";
import { checkNoGenericParamLeakage, formatViolations } from "../invariant";

const SRC_DEEP = `
function layer1<T>(f: (x: T) => T, init: T): T { return f(init); }
function layer2<T>(f: (x: T) => T, init: T): T { return layer1<T>(f, init); }
function layer3<T>(f: (x: T) => T, init: T): T { return layer2<T>(f, init); }
function layer4<T>(f: (x: T) => T, init: T): T { return layer3<T>(f, init); }
function layer5<T>(f: (x: T) => T, init: T): T { return layer4<T>(f, init); }

function mainDeep(): void {
	const factor: int32 = 5 as int32;
	const r = layer5<int32>((x) => (x * factor) as int32, 2 as int32);
}
`;

test "stress deep-nesting: no checker errors" {
	const result = checkOnly(SRC_DEEP);
	assert result.errors.length === 0;
}

test "stress deep-nesting: no GenericParam leakage at any layer" {
	const result = checkOnly(SRC_DEEP);
	const violations = checkNoGenericParamLeakage(result.program);
	if (violations.length > 0) { assert false, formatViolations(violations); }
	assert true;
}

test "stress deep-nesting: innermost closure typed Int32" {
	const result = checkOnly(SRC_DEEP);
	const main_fn = findFnDecl(result.program, "mainDeep");
	assert main_fn !== null;
	// Walk to find the arrow — it's nested inside layer5 call args
	let _findArrow: (node: any) => any = null as unknown as ((node: any) => any);
	_findArrow = (node: any): any => {
		if (node === null) return null;
		if (node.kind === 15) return node; // ArrowFunction
		const d: any = node.data;
		if (d !== null && d.programStmts !== undefined) {
			for (const s of d.programStmts) { const r = _findArrow(s); if (r !== null) return r; }
		}
		if (d !== null && d.statements !== undefined) {
			for (const s of d.statements) { const r = _findArrow(s); if (r !== null) return r; }
		}
		if (d !== null && d.fnBody !== undefined) { const r = _findArrow(d.fnBody); if (r !== null) return r; }
		if (d !== null && d.initializer !== undefined) { const r = _findArrow(d.initializer); if (r !== null) return r; }
		if (d !== null && d.callee !== undefined) {
			const r = _findArrow(d.callee); if (r !== null) return r;
			if (d.arguments !== undefined) {
				for (const a of d.arguments) { const r2 = _findArrow(a); if (r2 !== null) return r2; }
			}
		}
		return null;
	};
	const arrow = _findArrow(main_fn);
	assert arrow !== null;
	assert arrow.nodeType !== null;
	assert arrow.nodeType.typeChildren[0].kind === TypeKind.Int32;
}
