import { checkOnly } from "../helpers";

const SRC_LITERAL = `
const c: char = 65;
`;

const SRC_RUNTIME_INT = `
function k(n: int32): int32 { return n; }
const c: char = k(66);
`;

const SRC_INTO_INTEGERS = `
const c = 65 as char;
const a: int8 = c;
const b: int16 = c;
const d: int32 = c;
`;

const SRC_UNION = `
const c = 65 as char;
const u: char | null = 67;
const v: int32 | null = c;
`;

const SRC_OVERLOAD = `
function over(x: int32): string { return "int"; }
function over(x: string): string { return "str"; }
const c = 65 as char;
const s = over(c);
`;

const SRC_VALID = `
function k(n: int32): int32 { return n; }
function over(x: int32): string { return "int"; }
function over(x: char): string { return "char"; }
const a: char = 65 as char;
const b: char = k(66) as char;
const i8: int8 = a as int8;
const i16: int16 = a as int16;
const i32: int32 = b as int32;
const u: char | null = 67 as char;
const picked = over(a) + over(i32);
const same = a == b;
`;

test "an int literal into a char slot needs as char" {
	const text = checkOnly(SRC_LITERAL).errors.join("\n");
	assert text.contains("implicit int32 → char conversion crosses between char and a number"), "65 into char must fail the checker: " + text;
}

test "a run-time int into a char slot needs as char" {
	const text = checkOnly(SRC_RUNTIME_INT).errors.join("\n");
	assert text.contains("implicit int32 → char conversion crosses between char and a number"), "k(66) into char must fail the checker: " + text;
}

test "a char into int8, int16 and int32 slots needs as" {
	const text = checkOnly(SRC_INTO_INTEGERS).errors.join("\n");
	assert text.contains("char → int8"), "char into int8 must fail the checker: " + text;
	assert text.contains("char → int16"), "char into int16 must fail the checker: " + text;
	assert text.contains("char → int32"), "char into int32 must fail the checker: " + text;
}

test "a char member of a union takes only a char, and an int member only an int" {
	const text = checkOnly(SRC_UNION).errors.join("\n");
	assert text.contains("'int32' is not assignable to type 'char | null'"), "67 into char | null must fail the checker: " + text;
	assert text.contains("'char' is not assignable to type 'int32 | null'"), "a char into int32 | null must fail the checker: " + text;
}

test "a char argument matches no int32 overload" {
	const text = checkOnly(SRC_OVERLOAD).errors.join("\n");
	assert text.contains("No matching overload for 'over'"), "over(c) must not pick over(int32): " + text;
}

test "as char, as int32 and a char overload still check" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "explicit conversions must check: " + result.errors.join("\n");
}
