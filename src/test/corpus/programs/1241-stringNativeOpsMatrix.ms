// @stdout: parseInt 0x1F -31 9007199254740993 9223372036854775807
//
// The JS build reaches the native string operations, so their results on non-ASCII input must
// equal C's. Units are printed as hex numbers, so a lone surrogate is not a lane divergence.

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
	console.log("  charCodeAt " + s.charCodeAt(0).toString() + " " + s.charCodeAt(1).toString() + " " + s.charCodeAt(-1).toString() + " " + s.charCodeAt(99).toString());
	row("  charAt", s.charAt(0) + s.charAt(1) + s.charAt(-1) + s.charAt(99));
	row("  substring", s.substring(1) + "|" + s.substring(2, 1) + "|" + s.substring(-1, 2) + "|" + s.substring(1, 99) + "|" + s.substring(99, -5));
	row("  slice", s.slice(1) + "|" + s.slice(-2) + "|" + s.slice(1, 2) + "|" + s.slice(2, 1) + "|" + s.slice(-3, -1));
}


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
