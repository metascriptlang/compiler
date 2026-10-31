import { checkOnly } from "../helpers";

const SRC_FOR_OF = `
let n = 0;
for (const ch of "hello") { if (ch == "e") n += 1; }
`;

const SRC_SIDES = `
const c = 97 as char;
const a = "a" == c;
const b = c != "a";
const d = c === "ab";
`;

const SRC_STORED_TEXT = `
const c = 97 as char;
const s: string = "a" + "b";
const a = c == s;
const b = s != c;
const d = c === s;
`;

const SRC_BYTE = `
const b: uint8 = 97;
const a = b == "a";
const d = "a" != b;
`;

const SRC_SWITCH = `
const c = 97 as char;
switch (c) {
	case "a": break;
	default: break;
}
`;

const SRC_VALID = `
const c = 97 as char;
const d = 98 as char;
const a = c == "a".code;
const b = "a".code != c;
const e = c == d;
const f = c == 97;
const g = "a" == "a";
`;

test "a char compared with a one-character string is refused as no overlap" {
	const text = checkOnly(SRC_FOR_OF).errors.join("\n");
	assert text.contains("This comparison appears to be unintentional because the types 'char' and"), "ch == \"e\" must fail the checker: " + text;
	assert text.contains("compare with its code"), "the error must name the fix: " + text;
}

test "a char compared with a string is refused on either side and for a longer literal" {
	const text = checkOnly(SRC_SIDES).errors.join("\n");
	assert text.split("This comparison appears to be unintentional").length == 4, "three comparisons must fail: " + text;
}

test "a char compared with a string that is not a literal is refused on either side" {
	const text = checkOnly(SRC_STORED_TEXT).errors.join("\n");
	assert text.split("This comparison appears to be unintentional").length == 4, "three comparisons must fail: " + text;
	assert text.contains("compare with its code"), "the error must name the fix: " + text;
}

test "a uint8 compared with a string is refused" {
	const text = checkOnly(SRC_BYTE).errors.join("\n");
	assert text.split("cannot be applied to types").length == 3, "both comparisons must fail: " + text;
}

test "a char switch with a string case is refused" {
	const text = checkOnly(SRC_SWITCH).errors.join("\n");
	assert text.contains("is not comparable to the switch value of type 'char'"), "case \"a\" on a char must fail: " + text;
}

test "a char compares with its code, a char and a number, and strings with strings" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "char/number/string comparisons must check: " + result.errors.join("\n");
}
