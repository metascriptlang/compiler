// @stdout: Unicode casing: 39 cases OK

struct Case {
	name: string;
	input: string;
	expected: string;
	upper: boolean;
}

const high = "\uD800";
const low = "\uDC00";
const cases: Case[] = [
	{ name: "empty lower", input: "", expected: "", upper: false },
	{ name: "empty upper", input: "", expected: "", upper: true },
	{ name: "ASCII lower", input: "HELLO", expected: "hello", upper: false },
	{ name: "ASCII upper", input: "hello", expected: "HELLO", upper: true },
	{ name: "ASCII stable", input: "42 -_", expected: "42 -_", upper: true },
	{ name: "Vietnamese lower", input: "ĐỆ HÉLLO", expected: "đệ héllo",
		upper: false },
	{ name: "Vietnamese upper", input: "đệ", expected: "ĐỆ", upper: true },
	{ name: "dotted I", input: "İSPANYOL", expected: "i\u0307spanyol",
		upper: false },
	{ name: "sharp S", input: "ßfoo", expected: "SSFOO", upper: true },
	{ name: "capital sharp S", input: "ẞ", expected: "ß", upper: false },
	{ name: "ligature", input: "ﬁoo", expected: "FIOO", upper: true },
	{ name: "triple expansion", input: "ﬃ", expected: "FFI", upper: true },
	{ name: "Greek expansion", input: "ΐ", expected: "Ι\u0308\u0301",
		upper: true },
	{ name: "lone sigma", input: "Σ", expected: "σ", upper: false },
	{ name: "final sigma", input: "ΟΣ", expected: "ος", upper: false },
	{ name: "nonfinal sigma", input: "ΟΣΑ", expected: "οσα", upper: false },
	{ name: "uncased prefix", input: " Σ", expected: " σ", upper: false },
	{ name: "uncased prefix in Unicode17", input: "ʕΣ", expected: "ʕσ",
		upper: false },
	{ name: "ignorable modifier", input: "ʰΣ", expected: "ʰσ", upper: false },
	{ name: "ignorable mark", input: "\u0345Σ", expected: "\u0345σ",
		upper: false },
	{ name: "feminine ordinal", input: "ªΣ", expected: "ªς", upper: false },
	{ name: "masculine ordinal", input: "ºΣ", expected: "ºς", upper: false },
	{ name: "roman numeral", input: "ⅠΣ", expected: "ⅰς", upper: false },
	{ name: "sigma before cased", input: "ΣA", expected: "σa", upper: false },
	{ name: "sigma before roman", input: "ΣⅠ", expected: "σⅰ",
		upper: false },
	{ name: "look through mark", input: "ΑΣ\u0345A", expected: "ασ\u0345a",
		upper: false },
	{ name: "final before emoji", input: "ΑΣ🚀", expected: "ας🚀",
		upper: false },
	{ name: "astral upper", input: "𐐨", expected: "𐐀", upper: true },
	{ name: "astral lower", input: "𐐀", expected: "𐐨", upper: false },
	{ name: "Unicode16 Cyrillic", input: "\u1c89", expected: "\u1c8a",
		upper: false },
	{ name: "new Cyrillic sigma context", input: "\u1c89Σ",
		expected: "\u1c8aς", upper: false },
	{ name: "new Latin lower", input: "\ua7cb", expected: "\u0264",
		upper: false },
	{ name: "new Latin upper", input: "\u0264", expected: "\ua7cb",
		upper: true },
	{ name: "NUL upper", input: "á\0ß", expected: "Á\0SS", upper: true },
	{ name: "NUL lower", input: "Á\0B", expected: "á\0b", upper: false },
	{ name: "lone high", input: high, expected: high, upper: true },
	{ name: "lone low", input: low + "x", expected: low + "X", upper: true },
	{ name: "high between letters", input: "A" + high + "B",
		expected: "a" + high + "b", upper: false },
	{ name: "high before sigma", input: high + "Σ", expected: high + "σ",
		upper: false },
];

for (const item of cases) {
	const actual = item.upper ? item.input.toUpperCase() :
		item.input.toLowerCase();
	if (actual != item.expected) {
		throw new Error(item.name + ": case conversion differs");
	}
}
console.log("Unicode casing: " + String(cases.length) + " cases OK");
