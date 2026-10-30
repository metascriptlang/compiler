// Parity program — the LANG.md "Index-Space Contract" as a real binary on every
// lane. One UTF-8 byte buffer, two index spaces: the TS-named surface (length,
// indexOf, slice, charAt, pad*) is UTF-16 CODE-UNIT indexed, the byte* surface
// is byte indexed. bug068 pins this at the unit-test tier on C only; this pins
// it C↔JS↔orc↔danger, where the two backends reach the answer differently
// (C walks WTF-8, node delegates to native UTF-16).
//
// Lone surrogate halves are printed as NUMBERS, never as text: node writes an
// unpaired half as U+FFFD while C writes raw WTF-8, so printing them would be a
// lane divergence in the test, not in the compiler.

function showN(label: string, v: int64): void {
	console.log(label + "=" + v.toString());
}

function show(label: string, v: string): void {
	console.log(label + "=[" + v + "]");
}

function spaces(label: string, s: string): void {
	console.log(label + " units=" + s.length.toString() + " bytes=" + s.byteLength().toString());
}

function main(): void {
	const latin = "héxlo";
	const dash = "a—xb";
	const cjk = "日本語x";
	const astral = "👍x";
	const mixed = "é—日👍";

	spaces("latin", latin);
	spaces("dash", dash);
	spaces("cjk", cjk);
	spaces("astral", astral);
	spaces("mixed", mixed);
	spaces("ascii", "plain");

	showN("latinIdx", latin.indexOf("x"));
	showN("dashIdx", dash.indexOf("x"));
	showN("cjkIdx", cjk.indexOf("x"));
	showN("astralIdx", astral.indexOf("x"));
	showN("dashLastIdx", dash.lastIndexOf("x"));
	showN("mixedIdxDash", mixed.indexOf("—"));
	showN("missingIdx", latin.indexOf("zz"));

	show("latinPad", latin.padStart(6, "."));
	show("dashPad", dash.padStart(6, "."));
	show("cjkPad", cjk.padEnd(6, "."));
	show("astralPad", astral.padStart(6, "."));
	show("noPad", "abcdef".padStart(3, "."));

	show("latinSlice", latin.slice(1, 3));
	show("cjkSlice", cjk.slice(1, 3));
	show("astralWhole", astral.slice(0, 2));
	show("dashIdx1", dash[1]);
	show("latinIdx1", latin[1]);
	show("cjkCharAt", cjk.charAt(2));

	showN("astralHi", astral.charAt(0).charCodeAt(0));
	showN("astralLo", astral.charAt(1).charCodeAt(0));
	showN("astralTail", astral.charCodeAt(2));
	showN("astralIdxHi", astral[0].charCodeAt(0));
	showN("astralSliceLoLen", astral.slice(1, 3).length);
	showN("astralSliceLo0", astral.slice(1, 3).charCodeAt(0));
	showN("astralSliceLo1", astral.slice(1, 3).charCodeAt(1));
	showN("latinCode1", latin.charCodeAt(1));
	showN("cjkCode0", cjk.charCodeAt(0));

	showN("latinByte1", latin.byteAt(1));
	show("latinByteSlice", latin.byteSlice(0, 1));
	show("cjkByteSlice", cjk.byteSlice(0, 3));
}
main();
