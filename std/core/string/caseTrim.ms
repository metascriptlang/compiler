// Tests for trim and case conversion: the ECMAScript result on C and JS.

function units(s: string): string {
	let out = "";
	for (let i = 0; i < s.length; i++) out += (i == 0 ? "" : " ") + s.charCodeAt(i).toString(16);
	return out;
}

test "ASCII input converts as before" {
	assert "Hello, World 123".toUpperCase() == "HELLO, WORLD 123";
	assert "Hello, World 123".toLowerCase() == "hello, world 123";
	assert "  a b \t\n".trim() == "a b";
	assert "  a b ".trimStart() == "a b ";
	assert "  a b ".trimEnd() == "  a b";
	assert "".trim() == "";
	assert "   ".trim() == "";
	assert "".toUpperCase() == "";
}

test "Latin-1 letters change case" {
	assert "école".toUpperCase() == "ÉCOLE";
	assert "ÉCOLE".toLowerCase() == "école";
	assert units("ÿ".toUpperCase()) == "178";
}

test "sharp s and ligatures expand to several letters" {
	assert "Straße".toUpperCase() == "STRASSE";
	assert "ﬁ".toUpperCase() == "FI";
	assert "ﬃx".toUpperCase() == "FFIX";
}

test "a sigma ending a word lowercases to the final form" {
	assert units("ΣΑΣ".toLowerCase()) == "3c3 3b1 3c2";
	assert units("Σ".toLowerCase()) == "3c3";
	assert units("a.Σb".toLowerCase()) == "61 2e 3c3 62";
	assert units("aΣ.b".toLowerCase()) == "61 3c3 2e 62";
	assert units("aΣ".toLowerCase()) == "61 3c2";
}

test "dotted capital I lowercases to i and a combining dot" {
	assert units("İ".toLowerCase()) == "69 307";
}

test "characters outside the BMP change case" {
	assert units("𐐨".toUpperCase()) == "d801 dc00";
	assert units("𐐀".toLowerCase()) == "d801 dc28";
	assert units("😀a".toUpperCase()) == "d83d de00 41";
}

test "trim removes ECMAScript white space and line terminators" {
	assert units(" x ".trim()) == "78";
	assert units("﻿x﻿".trim()) == "78";
	assert units(" x ".trim()) == "78";
	assert units("　x　".trim()) == "78";
	assert units(" x ".trim()) == "78";
	assert units(" x ".trim()) == "78";
	assert units(" x ".trimStart()) == "78 2003";
	assert units(" x ".trimEnd()) == "2003 78";
}

test "trim keeps the next line and mongolian vowel separator" {
	assert units("\u0085᠎x᠎\u0085".trim()) == "85 180e 78 180e 85";
	assert units("​x​".trim()) == "200b 78 200b";
}

test "an encoded surrogate passes through unchanged" {
	assert units("\ud83dx".toUpperCase()) == "d83d 58";
	assert units("x\ude00".toLowerCase()) == "78 de00";
}
