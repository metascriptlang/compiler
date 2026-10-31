import { foldFileName } from "./fileCaseFold";

struct FoldCase {
	input: string;
	expected: string;
}

const cases: FoldCase[] = [
	{ input: "", expected: "" },
	{ input: "ClAnG.ExE", expected: "clang.exe" },
	{ input: "ĐỆ.DLL", expected: "đệ.dll" },
	{ input: "Straße.dll", expected: "strasse.dll" },
	{ input: "STRASSE.DLL", expected: "strasse.dll" },
	{ input: "ẞ", expected: "ss" },
	{ input: "ı", expected: "ı" },
	{ input: "I", expected: "i" },
	{ input: "İ", expected: "i\u0307" },
	{ input: "Σςσ", expected: "σσσ" },
	{ input: "ΟΣ", expected: "οσ" },
	{ input: "µ", expected: "μ" },
	{ input: "ſ", expected: "s" },
	{ input: "K", expected: "k" },
	{ input: "Å", expected: "å" },
	{ input: "ﬃ", expected: "ffi" },
	{ input: "ﬓ", expected: "մն" },
	{ input: "ᾈ", expected: "ἀι" },
	{ input: "ΐ", expected: "ι\u0308\u0301" },
	{ input: "É", expected: "é" },
	{ input: "E\u0301", expected: "e\u0301" },
	{ input: "Ꭰ", expected: "Ꭰ" },
	{ input: "ꭰ", expected: "Ꭰ" },
	{ input: "\u{10400}", expected: "\u{10428}" },
	{ input: "\u{1D400}", expected: "\u{1D400}" },
	{ input: "\uA7CE", expected: "\uA7CF" },
	{ input: "A\0Z", expected: "a\0z" },
	{ input: "\uD800", expected: "\uD800" },
	{ input: "\uDC00", expected: "\uDC00" },
	{ input: "\uD800A\uDC00", expected: "\uD800a\uDC00" },
	{ input: "😀 A", expected: "😀 a" },
	{ input: "path/Σ.ß", expected: "path/σ.ss" },
];

for (let i: int32 = 0; i < cases.length; i += 1) {
	const row = cases[i];
	const folded = foldFileName(row.input);
	if (!folded.ok) { throw new Error(folded.error); }
	if (folded.value != row.expected) {
		throw new Error("file casefold differs at case " + String(i));
	}
	const again = foldFileName(folded.value);
	if (!again.ok || again.value != folded.value) {
		throw new Error("file casefold is not idempotent at " + String(i));
	}
}
if (cases.length != 32) { throw new Error("file casefold case count changed"); }
console.log("File casefold: 32 cases OK");
