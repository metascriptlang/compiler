// @stdout: mixed 61.fffd.62.fffd.fffd./11
// @stdout: trunc2 fffd./3
// @stdout: trunc3 fffd./3
// @stdout: trunc4 fffd./3
// @stdout: overlongC0 fffd.fffd.41./7
// @stdout: overlongE0 fffd.fffd.fffd./9
// @stdout: f5 fffd.fffd.fffd.fffd./12
// @stdout: above10ffff fffd.fffd.fffd.fffd./12
// @stdout: loneCont fffd.41.fffd./7
// @stdout: loneHigh d800.42./4
// @stdout: loneLow 41.dfff./4
// @stdout: pair d83d.de00./4
// @stdout: reversed de00.d83d./6
// @stdout: truncSurrogate fffd.fffd./6
// @stdout: valid e9.20ac.d83d.de00./9
// @stdout: roundTrip true 61.d800.62.dfff.63./9
// @stdout: span fffd.41./4
// @stdout: empty /0 /0
// note: uint8[].asString() and Readonly<Span<uint8>>.asString() decode WTF-8 on every backend: an ill-formed sequence reads as one U+FFFD per maximal subpart, as TextDecoder reads it, while an encoded surrogate stays and a split surrogate pair joins, so a string with a lone surrogate survives asBytes().asString(). Expected lines come from node (TextDecoder).

function codes(s: string): string {
	let o = "";
	for (let i = 0; i < s.length; i++) o += s.charCodeAt(i).toString(16) + ".";
	return `${o}/${s.asBytes().length}`;
}

function show(label: string, bytes: uint8[]): void {
	console.log(`${label} ${codes(bytes.asString())}`);
}

show("mixed", [0x61, 0xE2, 0x62, 0xFF, 0xC3]);
show("trunc2", [0xC3]);
show("trunc3", [0xE2, 0x82]);
show("trunc4", [0xF0, 0x9F, 0x98]);
show("overlongC0", [0xC0, 0x80, 0x41]);
show("overlongE0", [0xE0, 0x80, 0x80]);
show("f5", [0xF5, 0x80, 0x80, 0x80]);
show("above10ffff", [0xF4, 0x90, 0x80, 0x80]);
show("loneCont", [0x80, 0x41, 0xBF]);
show("loneHigh", [0xED, 0xA0, 0x80, 0x42]);
show("loneLow", [0x41, 0xED, 0xBF, 0xBF]);
show("pair", [0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80]);
show("reversed", [0xED, 0xB8, 0x80, 0xED, 0xA0, 0xBD]);
show("truncSurrogate", [0xED, 0xA0]);
show("valid", [0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80]);

const lone = "a\uD800b\uDFFFc";
const back = lone.asBytes().slice(0).asString();
console.log(`roundTrip ${back == lone} ${codes(back)}`);

function spanTail(whole: uint8[]): string {
	const view: Readonly<Span<uint8>> = whole;
	return view[1..5].asString();
}
console.log(`span ${codes(spanTail([0x7A, 0xF0, 0x9F, 0x98, 0x41]))}`);

function viewOf(bytes: uint8[]): string {
	const view: Readonly<Span<uint8>> = bytes;
	return view.asString();
}
console.log(`empty ${codes(([] as uint8[]).asString())} ${codes(viewOf([]))}`);
