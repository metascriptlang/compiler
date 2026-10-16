import { checkOnly } from "../helpers";

const SRC_MIXED = `
const c = 65 as char;
const i8: int8 = 1;
const i32: int32 = 2;
const f64: float64 = 1.5;
const n: number = 3;
const a = i8 + c;
const b = c - i32;
const d = c * f64;
const e = n / c;
`;

const SRC_CHAR_PAIR = `
const c = 65 as char;
const d = 66 as char;
const s = c + d;
const t = c - 1;
`;

const SRC_COMPOUND = `
const c = 65 as char;
let total: int32 = 0;
total += c;
let wide: float64 = 1;
wide *= c;
let next = c;
next += 1;
`;

const SRC_NEGATED = `
const c = 65 as char;
const n = -c;
`;

const SRC_VALID = `
const c = 65 as char;
const d = 66 as char;
const i32: int32 = 2;
const sum = (c as int32) + i32;
const back = ((c as int32) + 1) as char;
const negated = -(c as int32);
const literal = c == 65;
const ordered = c < d;
const same = c != d;
`;

function errorsOf(source: string): string {
	return checkOnly(source).errors.join("\n");
}

test "arithmetic that mixes a char with int8, int32, float64 or number needs as" {
	const text = errorsOf(SRC_MIXED);
	assert text.contains("operator '+' cannot be applied to 'int8' and 'char': a char is not a number — convert it with an explicit 'as int8'"), "int8 + char must fail the checker: " + text;
	assert text.contains("operator '-' cannot be applied to 'char' and 'int32'"), "char - int32 must fail the checker: " + text;
	assert text.contains("operator '*' cannot be applied to 'char' and 'float64'"), "char * float64 must fail the checker: " + text;
	assert text.contains("operator '/' cannot be applied to 'number' and 'char'"), "number / char must fail the checker: " + text;
}

test "arithmetic between two chars or a char and a literal needs as" {
	const text = errorsOf(SRC_CHAR_PAIR);
	assert text.contains("operator '+' cannot be applied to 'char' and 'char': a char is not a number — convert it with an explicit 'as int32'"), "char + char must fail the checker: " + text;
	assert text.contains("operator '-' cannot be applied to 'char' and 'int32'"), "char - 1 must fail the checker: " + text;
}

test "compound arithmetic with a char on either side needs as" {
	const text = errorsOf(SRC_COMPOUND);
	assert text.contains("operator '+=' cannot be applied to 'int32' and 'char'"), "total += c must fail the checker: " + text;
	assert text.contains("operator '*=' cannot be applied to 'float64' and 'char'"), "wide *= c must fail the checker: " + text;
	assert text.contains("operator '+=' cannot be applied to 'char' and 'int32'"), "next += 1 must fail the checker: " + text;
}

test "unary minus on a char needs as" {
	const text = errorsOf(SRC_NEGATED);
	assert text.contains("unary '-' cannot be applied to 'char': a char is not a number — convert it with an explicit 'as int32'"), "-c must fail the checker: " + text;
}

test "a converted char computes and a char compares with a literal or a char" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "explicit conversions and comparisons must check: " + result.errors.join("\n");
}
