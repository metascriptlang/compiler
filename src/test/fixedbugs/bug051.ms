// bug051 — macro-emitted object-literal call args skipped the excess-property check
//
// Symptom:    a macro that wraps its ObjectLiteral argument in a call to a
//             function with a typed struct param compiles CLEAN through the
//             checker even when the literal has a typo'd key; the C compiler
//             then fails with "no member named 'widht' in 'struct S'".
//             Found by Neon's createStyles macro (styleOf-wrapped entries).
//
// Roots:      (a) nodeToValue/valueToNode dropped ObjectLiteral keyLocations
//             (bridge.ms reconstructed with keyLocations: []), and
//             (b) the excess-property and duplicate-key diagnostics in
//             checkExprPass were gated on having a key location — with none,
//             the ERROR ITSELF was swallowed, not just its range.
//
// Fix:        bridge serializes keyLocations both ways (setLocs/readLocs);
//             the checker falls back to the literal's own location when key
//             locations are missing, so the diagnostic can never vanish.

import { compileToC } from "../helpers";

const srcExcess = `
import { Node, NodeKind } from "std/meta";

interface S { width: number | null; }

export function idS(s: S): S { return s; }

export macro mk(node: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: node.line, column: node.column,
		callee: { kind: NodeKind.Identifier, line: node.line, column: node.column, name: "idS" },
		arguments: [node],
	};
}

function main(): void {
	const x = mk({ widht: 5 });
}
`;

test "bug051: excess key in a macro-emitted call arg is a checker error" {
	const c = compileToC(srcExcess);
	assert !c.ok;
	assert c.error.indexOf("'widht' does not exist in type 'S'", 0) >= 0;
}

const srcDup = `
import { Node, NodeKind } from "std/meta";

interface S { width: number | null; }

export function idS(s: S): S { return s; }

export macro mk(node: Node): Node {
	return {
		kind: NodeKind.CallExpr, line: node.line, column: node.column,
		callee: { kind: NodeKind.Identifier, line: node.line, column: node.column, name: "idS" },
		arguments: [node],
	};
}

function main(): void {
	const x = mk({ width: 1, width: 2 });
}
`;

test "bug051: duplicate key in a macro-emitted call arg is a checker error" {
	const c = compileToC(srcDup);
	assert !c.ok;
	assert c.error.indexOf("field initialized twice: 'width'", 0) >= 0;
}
