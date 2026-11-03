// @stdout: upper e-acute [5] c9 43 4f 4c 45
// @stdout: upper sharp-s [7] 53 54 52 41 53 53 45
// @stdout: upper y-diaeresis [1] 178
// @stdout: upper ligature ffi [4] 46 46 49 58
// @stdout: upper astral [2] d801 dc00
// @stdout: lower final sigma [3] 3c3 3b1 3c2
// @stdout: lower sigma after dot [4] 61 2e 3c3 62
// @stdout: lower dotted I [2] 69 307
// @stdout: lower astral [2] d801 dc28
// @stdout: trim unicode spaces [1] 78
// @stdout: trimStart trimEnd [2] 78 2003 | [2] 2003 78
// @stdout: trim keeps NEL and mongolian vowel separator [5] 85 180e 78 180e 85
// @stdout: every code point upper 224777 lower 428832 trim 198084
// @stdout: sigma and mark contexts 621632
//
// trim and the case functions return the ECMAScript result on C, JS and the Raiser: Unicode WhiteSpace and
// LineTerminator, the full default case mapping with SpecialCasing, and Final_Sigma. The hashes cover
// every code point and a fuzz of sigma contexts, and equal what node answers.

function codePoint(n: number): string {
	return fromCodePoint(n);
}

function show(s: string): string {
	let out = "[" + s.length.toString() + "]";
	for (let i = 0; i < s.length; i++) out += " " + s.charCodeAt(i).toString(16);
	return out;
}

function hashOf(s: string, h: number): number {
	h = (h * 31 + s.length) % 1000003;
	for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 1000003;
	return h;
}

console.log("upper e-acute " + show("école".toUpperCase()));
console.log("upper sharp-s " + show("Straße".toUpperCase()));
console.log("upper y-diaeresis " + show("ÿ".toUpperCase()));
console.log("upper ligature ffi " + show("ﬃx".toUpperCase()));
console.log("upper astral " + show("𐐨".toUpperCase()));
console.log("lower final sigma " + show("ΣΑΣ".toLowerCase()));
console.log("lower sigma after dot " + show("a.Σb".toLowerCase()));
console.log("lower dotted I " + show("İ".toLowerCase()));
console.log("lower astral " + show("𐐀".toLowerCase()));
console.log("trim unicode spaces " + show("    ﻿　x　  ".trim()));
console.log("trimStart trimEnd " + show(" x ".trimStart()) + " | " + show(" x ".trimEnd()));
console.log("trim keeps NEL and mongolian vowel separator " + show("\u0085᠎x᠎\u0085".trim()));

const cases: string[] = [
	"", "Hello World", "  a b \t\n", "école", "Straße", "ΣΑΣ", "aΣ", "Σ", "a.Σb", "aΣ.b", "İ", "i̇I", "ﬁ", "ﬃx", "ŉ", "ǰ",
	"𐐀", "𐐨", "😀a", "ᾀ", "ᾳ", "ǅ", "ẞ", "ͅ", "µ", "K", "Ω", "\ud83dx", "x\ude00",
	" x ", "﻿x﻿", " x ", "　x　", " x ", " x ", " x ", "\u0085x\u0085", "᠎x᠎", "​x​", "\u000b\u000cx\u000b",
];
for (const s of cases) {
	console.log("in " + show(s));
	console.log(" trim " + show(s.trim()));
	console.log(" trimStart " + show(s.trimStart()));
	console.log(" trimEnd " + show(s.trimEnd()));
	console.log(" upper " + show(s.toUpperCase()));
	console.log(" lower " + show(s.toLowerCase()));
}

let hu: number = 7;
let hl: number = 7;
let ht: number = 7;
for (let c = 0; c <= 0x10ffff; c++) {
	if (c >= 0xd800 && c <= 0xdfff) continue;
	const s = codePoint(c);
	hu = hashOf(s.toUpperCase(), hu);
	hl = hashOf(s.toLowerCase(), hl);
	hl = hashOf(("a" + s + "b").toLowerCase(), hl);
	ht = hashOf((s + "x" + s).trim(), ht);
	ht = hashOf((" " + s + "\t").trim(), ht);
	ht = hashOf((s + "x" + s).trimStart(), ht);
	ht = hashOf((s + "x" + s).trimEnd(), ht);
}
console.log("every code point upper " + hu.toString() + " lower " + hl.toString() + " trim " + ht.toString());

const alphabet: number[] = [0x3a3, 0x3c3, 0x3c2, 0x61, 0x41, 0x2e, 0x27, 0x20, 0x301, 0x345, 0x1d7, 0x130, 0x131, 0xdf, 0x10400, 0x2019, 0x30, 0x5f, 0xad, 0x1f88, 0x2c, 0xa0, 0x3000, 0xfeff];
let seed: number = 12345;
let hf: number = 7;
for (let n = 0; n < 200000; n++) {
	let s = "";
	seed = (seed * 48271) % 2147483647;
	const len = 1 + ((seed % 7) as int32);
	for (let k = 0; k < len; k++) {
		seed = (seed * 48271) % 2147483647;
		s += codePoint(alphabet[(seed % alphabet.length) as int32]);
	}
	hf = hashOf(s.toLowerCase(), hf);
	hf = hashOf(s.toUpperCase(), hf);
	hf = hashOf(s.trim(), hf);
}
console.log("sigma and mark contexts " + hf.toString());
