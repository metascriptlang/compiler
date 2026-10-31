// @stdout: trim NBSP/FEFF/LS/EM space stay [3] a0 78 a0 | [3] feff 78 feff | [3] 2028 78 2029 | [3] 2003 78 3000
// @stdout: trim ASCII whitespace [3] 61 20 62
// @stdout: upper e-acute/sharp-s/y-diaeresis stay [4] e9 c9 df ff
// @stdout: lower dotted-I/dotless-i stay [4] 131 69 130 69
// @stdout: upper ASCII beside astral [5] d83d de00 41 d83d de00
// @stdout: parseInt 0x1F -31 9007199254740993 9223372036854775807
//
// The JS build reaches the native string operations only where they equal C. trim and the case
// functions are ASCII-only here, while native JS also strips U+00A0, U+FEFF, U+2028 and U+3000 and
// folds "é", "ß" and the dotted I, so every non-ASCII row below must come out unchanged on both
// backends. Units are printed as hex numbers, so a lone surrogate is not a lane divergence.

function show(s: string): string {
	let out = "[" + s.length.toString() + "]";
	for (let i = 0; i < s.length; i++) out += " " + s.charCodeAt(i).toString(16);
	return out;
}

function row(label: string, s: string): void {
	console.log(label + " " + show(s));
}

const matrix: string[] = [
	"", "  a b \t\n", "   ", "ABC xyz", "éÉßÿ", "ıiİI", " x ", "﻿x﻿",
	" x ", " x　", "​x", "\u0085x\u0085", "᠎x", "😀a😀", "\ud83dx", "x\ude00",
	"σΣς", "ﬁ", "ǅ", "ẞ", "ŉ", "á", "\u000b\u000cx\u000b",
];

for (const s of matrix) {
	row("in", s);
	row("  trim", s.trim());
	row("  trimStart", s.trimStart());
	row("  trimEnd", s.trimEnd());
	row("  upper", s.toUpperCase());
	row("  lower", s.toLowerCase());
	console.log("  charCodeAt " + s.charCodeAt(0).toString() + " " + s.charCodeAt(1).toString() + " " + s.charCodeAt(-1).toString() + " " + s.charCodeAt(99).toString());
	row("  charAt", s.charAt(0) + s.charAt(1) + s.charAt(-1) + s.charAt(99));
	row("  substring", s.substring(1) + "|" + s.substring(2, 1) + "|" + s.substring(-1, 2) + "|" + s.substring(1, 99) + "|" + s.substring(99, -5));
	row("  slice", s.slice(1) + "|" + s.slice(-2) + "|" + s.slice(1, 2) + "|" + s.slice(2, 1) + "|" + s.slice(-3, -1));
}

console.log("trim NBSP/FEFF/LS/EM space stay " + show(" x ".trim()) + " | " + show("﻿x﻿".trim()) + " | " + show(" x ".trim()) + " | " + show(" x　".trim()));
console.log("trim ASCII whitespace " + show(" \t\n a b\r\n ".trim()));
console.log("upper e-acute/sharp-s/y-diaeresis stay " + show("éÉßÿ".toUpperCase()));
console.log("lower dotted-I/dotless-i stay " + show("ıiİI".toLowerCase()));
console.log("upper ASCII beside astral " + show("😀a😀".toUpperCase()));

const numbers: string[] = [
	"12", " 12", " 12x", "+7", "-0", "0x1F", "-0x1f", "0xg", "0X", "0x", "1e3", "  ﻿42", "007", "12.9", "abc", "", "1_0", "٣12", "- 5",
	"9007199254740991", "-9007199254740991", "9007199254740993", "-9007199254740993", "9223372036854775807", "-9223372036854775808", "0x7fffffffffffffff",
];
for (const t of numbers) console.log("parseInt " + show(t) + " = " + t.parseInt().toString());
console.log("parseInt 0x1F " + "-0x1f".parseInt().toString() + " " + "9007199254740993".parseInt().toString() + " " + "9223372036854775807".parseInt().toString());

for (const t of ["9223372036854775808", "-9223372036854775809", "99999999999999999999999"]) {
	let thrown = false;
	try {
		t.parseInt();
	} catch (e) {
		thrown = true;
	}
	console.log("parseInt out of int64 throws " + t + " " + thrown.toString());
}
