// bug113 — a macro could not read a literal's VALUE, and the first accessor
// shape for it was unsound
//
// Symptom A:  node.data as NumberLiteralData / StringLiteralData reads nil in a
//             macro body (the VM wire is FLAT — there is no .data key), and the
//             flat read n.value is rejected by the checker ("field 'value' has
//             different types across Node variants"). Literal values were simply
//             unreachable from macros. Found by Neon's createStyles CSS renderer.
//
// Symptom B:  the obvious fix — one `numberValue(n): number` returning the value
//             as stored — is unsound in this VM. Arithmetic and compare opcodes
//             are TYPED (AddI64/AddF64, BltI64/BltF64) and the Raiser selects
//             them from the STATIC type of the expression, so an accessor whose
//             register kind varies with its input has its operands read through
//             the wrong opcode: numberValue(8.0) printed "8" and then compared
//             equal to nothing at all, behaving as 0 in >, -, + and ===.
//
// Fix:        Nim's split (macros.nim intVal/floatVal, vm.nim:1867-1881, where
//             decodeB(rkInt)/decodeB(rkFloat) fixes the result representation
//             per accessor): isFloatLiteral + intValue + floatValue + stringValue,
//             each with ONE static type and ONE register kind. Nim asks the node
//             KIND (nkIntLit vs nkFloatLit); our representation folds both into
//             NumberLiteral, so isFloatLiteral is that same question.
//
// The macro asserts what it reads and calls error() on mismatch, so a nil, a
// truncated, or a wrong-opcode read fails the compile — c.ok alone would not
// catch symptom B, which prints the right digits.

import { compileToCWithStd } from "../helpers";

const src = `
import { Node, NodeKind, childAt, isFloatLiteral, intValue, floatValue, stringValue } from "std/meta";

export macro readVals(node: Node): Node {
	const i = childAt(node, 0);
	const f = childAt(node, 1);
	const s = childAt(node, 2);

	if (isFloatLiteral(i)) { error("an integer literal must not report as float", node); }
	const iv = intValue(i);
	if (iv !== 8) { error("intValue read " + iv.toString() + ", want 8", node); }
	// Arithmetic and ordering go through the typed opcodes — this is what a
	// wrong register kind breaks while equality on the printed text still looks
	// right.
	if (iv + 1 !== 9) { error("intValue is not usable in arithmetic", node); }
	if (!(iv > 7)) { error("intValue is not usable in a comparison", node); }

	if (!isFloatLiteral(f)) { error("a fractional literal must report as float", node); }
	const fv = floatValue(f);
	if (fv !== 8.5) { error("floatValue read " + fv.toString() + ", want 8.5", node); }

	const sv = stringValue(s);
	if (sv !== "#334") { error("stringValue read '" + sv + "', want '#334'", node); }

	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: sv };
}

function main(): void {
	const x = readVals({ pad: 8, ratio: 8.5, color: "#334" });
}
`;

test "bug113: a macro reads literal values through kind-fixed accessors" {
	const c = compileToCWithStd(src);
	assert c.ok;
}

// The wire must carry float-ness as the stored register kind. Recomputing it
// from the magnitude (`value % 1 !== 0`) rewrote a round-tripped 8.0 into an
// integer literal — the node the macro received was not the node it was given.
const srcRoundTrip = `
import { Node, NodeKind, childAt, isFloatLiteral } from "std/meta";

export macro checkDotZero(node: Node): Node {
	const n = childAt(node, 0);
	if (!isFloatLiteral(n)) { error("8.0 lost its float-ness crossing the wire", node); }
	return { kind: NodeKind.StringLiteral, line: node.line, column: node.column, value: "ok" };
}

function main(): void {
	const x = checkDotZero({ v: 8.0 });
}
`;

test "bug113: a float literal keeps its kind across the macro wire" {
	const c = compileToCWithStd(srcRoundTrip);
	assert c.ok;
}
