// @stdout: edge ok
// note: Buffer encodings, floats, swaps, fills, searches and clamps give the same bytes on every backend; a hex decode stops at the first invalid digit and drops an odd trailing digit, as it does in node.

function check(name: string, ok: boolean): boolean {
	if (!ok) console.log("FAIL " + name);
	return ok;
}

function bytesOf(b: Buffer): string {
	let s = "";
	for (let i = 0; i < b.byteLength(); i++) s += (i > 0 ? " " : "") + b.byteAt(i).toString(16);
	return s;
}

function main(): void {
	let ok = true;

	ok = check("hexBadDigit", bytesOf(Buffer.fromString("0g1f", "hex")) == "") && ok;
	ok = check("hexStopsAtBadPair", bytesOf(Buffer.fromString("01g1ff", "hex")) == "1") && ok;
	ok = check("hexOdd", bytesOf(Buffer.fromString("abc", "hex")) == "ab") && ok;
	ok = check("hexUpper", bytesOf(Buffer.fromString("AbCd", "hex")) == "ab cd") && ok;
	ok = check("b64Padding", bytesOf(Buffer.fromString("YWJjZA==", "base64")) == "61 62 63 64") && ok;
	ok = check("b64Encode", Buffer.fromArray([0xfb, 0xff]).toStringEncoded("base64", 0, 2) == "+/8=") && ok;

	const f = Buffer.alloc(16);
	f.writeFloatBE(-0.15625, 0);
	f.writeFloatLE(1.0e-45, 4);
	f.writeDoubleLE(0.1, 8);
	ok = check("floatBytes", bytesOf(f) == "be 20 0 0 1 0 0 0 9a 99 99 99 99 99 b9 3f") && ok;
	ok = check("floatRead", f.readFloatBE(0) == -0.15625 && f.readFloatLE(4) > 1.0e-46 && f.readFloatLE(4) < 1.0e-44 && f.readDoubleLE(8) == 0.1) && ok;
	const nan = Buffer.alloc(4);
	nan.writeFloatLE(0.0 / 0.0, 0);
	ok = check("floatNaN", bytesOf(nan) == "0 0 c0 7f" && nan.readFloatLE(0) != nan.readFloatLE(0)) && ok;
	const inf = Buffer.alloc(8);
	inf.writeDoubleBE(-1.0 / 0.0, 0);
	ok = check("doubleInf", bytesOf(inf) == "ff f0 0 0 0 0 0 0" && inf.readDoubleBE(0) == -1.0 / 0.0) && ok;

	const six = Buffer.alloc(8);
	six.writeIntBE(-2, 1, 6);
	ok = check("int6", bytesOf(six) == "0 ff ff ff ff ff fe 0" && six.readIntBE(1, 6) == -2 && six.readUIntBE(1, 6) == 281474976710654) && ok;

	const sw = Buffer.fromArray([1, 2, 3, 4, 5, 6, 7, 8]);
	sw.swap64();
	ok = check("swap64", bytesOf(sw) == "8 7 6 5 4 3 2 1") && ok;

	const fl = Buffer.alloc(7);
	fl.fillString("ab", 1, 99, "utf8");
	ok = check("fillString", bytesOf(fl) == "0 61 62 61 62 61 62") && ok;
	fl.fillBuffer(Buffer.fromArray([9]), -3, 2);
	ok = check("fillBuffer", bytesOf(fl) == "9 9 62 61 62 61 62") && ok;

	const hay = Buffer.fromArray([1, 2, 1, 2, 1]);
	ok = check("indexOfEmpty", hay.indexOfBuffer(Buffer.alloc(0), 7) == 7 && hay.indexOf(2, 9) == -1 && hay.lastIndexOf(1, 99) == 4) && ok;

	ok = check("rangeClamp", Buffer.fromArray([65, 66, 67]).toStringEncoded("utf8", -4, 99) == "ABC" && Buffer.fromArray([65]).toStringEncoded("utf8", 1, 1) == "") && ok;
	ok = check("utf8Lossy", Buffer.fromArray([0x61, 0xf0, 0x9f, 0x61]).toStringEncoded("utf8", 0, 4) == "a�a") && ok;

	console.log(ok ? "edge ok" : "edge FAILED");
}

main();
