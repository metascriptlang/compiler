// Parity program — float arithmetic inside a macro body picks the float opcode
// from the static type the checker assigned, not from how the literal was spelled
// or how far the value travelled. Every cell below was wrong before: the engine
// marked a register "float" only when a literal with a visible fraction sat in the
// same expression, so `2.0` (prints as "2") and any value arriving through a copy,
// a return, an array element or a host bridge fell back to integer opcodes and
// read 0 out of the float slot.
//
// @stdout: 1|1|1|1|1|T|0.75|-0.5|3|3.5
// @exit: 0

import { Node, NodeKind, floatValue } from "std/meta";

function twiceF(x: float64): float64 { return x * 2.0; }

macro arith(v: Node): Node {
	const fromBridge = floatValue(v);
	const direct: float64 = 0.5;
	const copied = direct;
	const elems: float64[] = [0.5];
	let sum = 0.0;
	for (const e of elems) { sum = sum + e; }

	const viaBridge = fromBridge * 2.0;
	const viaCopy = copied * 2.0;
	const viaCall = twiceF(0.5);
	const viaElement = elems[0] * 2.0;
	const viaLoop = sum * 2.0;
	const compared = fromBridge > 0;
	const added = fromBridge + 0.25;
	const negated = -fromBridge;

	const li: int32 = 7;
	const ri: int32 = 2;
	const intDiv = li / ri;
	const floatDiv = (li as float64) / (ri as float64);

	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column,
		value: viaBridge.toString() + "|" + viaCopy.toString() + "|" + viaCall.toString()
			+ "|" + viaElement.toString() + "|" + viaLoop.toString()
			+ "|" + (compared ? "T" : "F") + "|" + added.toString() + "|" + negated.toString()
			+ "|" + intDiv.toString() + "|" + floatDiv.toString() };
}

console.log(arith(0.5));
