// Stress: 5-level deep nested generic calls with closures at multiple
// levels. Verifies bindings substitute correctly through each layer
// without contamination between layers.
//
// Each generic call site is independent — explicit `<int32>` at one layer
// must not leak into another. Closures at any level must see concrete types.

import { TypeKind, Node, NodeKind } from "../../../ast/node";
import { forEachChild } from "../../../ast/visitor";
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

// Depth-first search for the first ArrowFunction node — the arrow is nested
// inside layer5 call args.
function findArrow(node: Node): Node {
	if (node === null) return null as unknown as Node;
	if (node.kind === NodeKind.ArrowFunction) return node;
	let found: Node = null as unknown as Node;
	forEachChild(node, (child: Node): void => {
		if (found === null) {
			const r = findArrow(child);
			if (r !== null) found = r;
		}
	});
	return found;
}

test "stress deep-nesting: innermost closure typed Int32" {
	const result = checkOnly(SRC_DEEP);
	const main_fn = findFnDecl(result.program, "mainDeep");
	assert main_fn !== null;
	const arrow = findArrow(main_fn);
	assert arrow !== null;
	assert arrow.nodeType !== null;
	assert arrow.nodeType.typeChildren[0].kind === TypeKind.Int32;
}
