// bug500 — a number operand of a bitwise operator was range-checked instead of wrapped on C
//
// Symptom:    `3000000000 | 0` on a number raised "value 3000000000 not in range" on C
//             (JS prints -1294967296), and under --danger the operand went through an
//             undefined double to int32 cast (NaN | 0 printed -2147483648).
// Root cause: the checker converts the operand to int32, and the native range-check pass
//             treated that conversion like an explicit `as int32`.
// Fix:        a number operand of `| & ^ << >> >>>` and `~` is converted by msToInt32
//             (ECMAScript ToInt32) before range checks run, in every build mode.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug500: a number operand of | wraps by ToInt32 on C" {
	const c = cOf("export function f(v: number): int32 { return v | 0; }\n");
	assert c.contains("msToInt32(v)");
	assert !c.contains("msCheckRangeI32");
}

test "bug500: both number operands of a shift wrap by ToInt32 on C" {
	const c = cOf("export function f(v: number, n: number): int32 { return v << n; }\n");
	assert c.contains("msToInt32(v)");
	assert c.contains("msToInt32(n)");
}

test "bug500: the operand of ~ on a number wraps by ToInt32 on C" {
	assert cOf("export function f(v: number): int32 { return ~v; }\n").contains("~msToInt32(v)");
}

test "bug500: an explicit number as int32 keeps its range check on C" {
	assert cOf("export function f(v: number): int32 { return v as int32; }\n").contains("msCheckRangeI32(v");
}
