// Parity program — the byte-space surface and the uint8[] <-> string bridge.
// This is the seam the C backend owns natively (the payload IS UTF-8) while the
// JS backend has to encode and decode around a UTF-16 string, so agreement here
// is not free. Covers the shapes behind bug064-bug067: push dispatch on uint8[],
// asBytes on an rvalue receiver, asString on a temporary, and a literal-backed
// view being pushed into.

function showN(label: string, v: int64): void {
	console.log(label + "=" + v.toString());
}

function show(label: string, v: string): void {
	console.log(label + "=[" + v + "]");
}

function bytesOf(label: string, s: string): void {
	const b = s.asBytes();
	let acc = "";
	for (const x of b) { acc = acc + x.toString() + " "; }
	console.log(label + " n=" + b.length.toString() + " " + acc.trimEnd());
}

function main(): void {
	const ascii = "AZ";
	const latin = "hé";
	const cjk = "日";
	const astral = "👍";

	showN("blAscii", ascii.byteLength());
	showN("blLatin", latin.byteLength());
	showN("blCjk", cjk.byteLength());
	showN("blAstral", astral.byteLength());
	showN("blEmpty", "".byteLength());

	showN("byteAt0", ascii.byteAt(0));
	showN("byteAt1", ascii.byteAt(1));
	showN("latinByte1", latin.byteAt(1));
	showN("latinByte2", latin.byteAt(2));

	show("byteSliceHead", "abcdef".byteSlice(0, 3));
	show("byteSliceMid", "abcdef".byteSlice(2, 4));
	show("byteSliceEmpty", "abcdef".byteSlice(3, 3));
	show("byteSliceLatin", latin.byteSlice(0, 1));
	show("byteSliceCjk", cjk.byteSlice(0, 3));

	bytesOf("bAscii", ascii);
	bytesOf("bLatin", latin);
	bytesOf("bCjk", cjk);
	bytesOf("bAstral", astral);
	bytesOf("bEmpty", "");
	bytesOf("bRvalue", "A" + "Z");

	const round = latin.asBytes().asString();
	show("roundLatin", round);
	showN("roundLatinLen", round.length);
	show("roundCjk", cjk.asBytes().asString());
	show("roundAstral", astral.asBytes().asString());
	show("roundTemp", ("hé" + "日").asBytes().asString());

	const built: uint8[] = [];
	built.push(104);
	built.push(105);
	built.push(33);
	show("builtStr", built.asString());
	showN("builtLen", built.length);

	const grown = "ab".asBytes();
	grown.push(99);
	show("grownStr", grown.asString());
	showN("grownLen", grown.length);

	let sum = 0;
	for (const x of "abcdef".asBytes()) { sum = sum + (x as int32); }
	showN("byteSum", sum as int64);
}
main();
