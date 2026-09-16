// Parity program — the numeric surface a macro body can evaluate at compile time
// matches what the same expressions produce at runtime: float `%`, `**` on floats
// and on integers, `as` between float and integer widths, the std math externs
// and the readonly Math constants.
//
// @stdout: 1.5|8|1024|7|-7|44|3.5|3|2.5|1024|3.141592653589793
// @exit: 0

import { Node, NodeKind } from "std/meta";

macro mathAtCompileTime(v: Node): Node {
	const a: float64 = 7.5;
	const b: float64 = 2.0;
	const i: int32 = 2;
	const j: int32 = 10;
	const f: float64 = 7.9;
	const g: float64 = -7.9;
	const w: int32 = 300;
	const floatMod = a % b;
	const floatPow = b ** 3.0;
	const intPow = i ** j;
	const truncated = f as int32;
	const truncatedNeg = g as int32;
	const wrapped = w as uint8;
	const widened = (j as float64) / 4.0 + 1.0;
	const root = Math.sqrt(9.0);
	const magnitude = Math.abs(-2.5);
	const power = Math.pow(2.0, 10.0);
	return { kind: NodeKind.StringLiteral, line: v.line, column: v.column,
		value: floatMod.toString() + "|" + floatPow.toString() + "|" + intPow.toString()
			+ "|" + truncated.toString() + "|" + truncatedNeg.toString() + "|" + wrapped.toString()
			+ "|" + widened.toString() + "|" + root.toString() + "|" + magnitude.toString()
			+ "|" + power.toString() + "|" + Math.PI.toString() };
}

const a: float64 = 7.5;
const b: float64 = 2.0;
const i: int32 = 2;
const j: int32 = 10;
const f: float64 = 7.9;
const g: float64 = -7.9;
const w: int32 = 300;
console.log(mathAtCompileTime(0));
console.log(`${a % b}|${b ** 3.0}|${i ** j}|${f as int32}|${g as int32}|${w as uint8}|${(j as float64) / 4.0 + 1.0}|${Math.sqrt(9.0)}|${Math.abs(-2.5)}|${Math.pow(2.0, 10.0)}|${Math.PI}`);
