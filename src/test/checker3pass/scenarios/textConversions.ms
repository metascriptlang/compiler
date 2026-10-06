import { checkOnly } from "../helpers";

const SRC_ELEMENT = `
const t = "xyz";
const n = t[1] as int32;
`;

const SRC_PARAM = `
function first(s: string): int32 { return s[0] as int32; }
`;

const SRC_TO_STRING = `
const n: int32 = 5;
const s = n as string;
`;

const SRC_BOOL_CHAR = `
const s: string = "a";
const b = s as boolean;
const c = s as char;
`;

const SRC_VALID = `
const t = "xyz";
const code: int32 = t.charCodeAt(1);
const byte = t.byteAt(1);
const big = "0xff" as bigint;
const x: string | int32 = 3;
const n = x as int32;
for (const c of t) { const k = c as int32; }
`;

test "a string element converted with as int32 is a checker error naming the way out" {
	const text = checkOnly(SRC_ELEMENT).errors.join("\n");
	assert text.contains("cannot convert string to int32"), "t[1] as int32 must fail the checker: " + text;
	assert text.contains("charCodeAt"), "the error must name charCodeAt: " + text;
}

test "a string parameter's element converted with as int32 is a checker error" {
	const text = checkOnly(SRC_PARAM).errors.join("\n");
	assert text.contains("cannot convert string to int32"), "s[0] as int32 must fail the checker: " + text;
}

test "a number converted with as string is a checker error naming String(x)" {
	const text = checkOnly(SRC_TO_STRING).errors.join("\n");
	assert text.contains("cannot convert int32 to string"), "n as string must fail the checker: " + text;
	assert text.contains("String(x)"), "the error must name String(x): " + text;
}

test "a string converted with as boolean or as char is a checker error" {
	const text = checkOnly(SRC_BOOL_CHAR).errors.join("\n");
	assert text.contains("cannot convert string to boolean"), "s as boolean must fail the checker: " + text;
	assert text.contains("cannot convert string to char"), "s as char must fail the checker: " + text;
}

test "character codes, bytes, bigint parsing and union members still convert" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "valid conversions must check: " + result.errors.join("\n");
}
