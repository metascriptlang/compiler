// @stdout: range ok
// note: a Buffer read or write outside the buffer, an integer outside its width and a byteLength outside 1..6 throw a catchable RangeError on every backend, as node does; C used to answer 0 and drop the write.

function check(name: string, ok: boolean): boolean {
	if (!ok) console.log("FAIL " + name);
	return ok;
}

function throwsRange(f: () => number): boolean {
	try {
		f();
	} catch (e) {
		return e instanceof RangeError;
	}
	return false;
}

function main(): void {
	let ok = true;
	const b = Buffer.fromArray([1, 2, 3, 4, 5, 6, 7, 8]);
	const off = (n: number): number => n;

	ok = check("readPastEnd", throwsRange((): number => b.readUInt32LE(off(6)))) && ok;
	ok = check("readNegative", throwsRange((): number => b.readInt16BE(off(-1)))) && ok;
	ok = check("readDoublePastEnd", throwsRange((): number => b.readDoubleLE(off(1)))) && ok;
	ok = check("readUInt8PastEnd", throwsRange((): number => b.readUInt8(off(8)))) && ok;
	ok = check("readWidthSeven", throwsRange((): number => b.readUIntBE(off(0), off(7)))) && ok;
	ok = check("readWidthZero", throwsRange((): number => b.readUIntLE(off(0), off(0)))) && ok;
	ok = check("writePastEnd", throwsRange((): number => b.writeUInt32BE(9, off(6)))) && ok;
	ok = check("writeUInt8PastEnd", throwsRange((): number => b.writeUInt8(1, off(8)))) && ok;
	ok = check("writeValueTooBig", throwsRange((): number => b.writeUInt8(off(256), 0))) && ok;
	ok = check("writeValueNegative", throwsRange((): number => b.writeUInt16LE(off(-1), 0))) && ok;
	ok = check("writeIntTooSmall", throwsRange((): number => b.writeInt8(off(-129), 0))) && ok;
	ok = check("writeInt32TooBig", throwsRange((): number => b.writeInt32BE(off(2147483648), 0))) && ok;
	ok = check("writeWidthValue", throwsRange((): number => b.writeUIntLE(off(65536), 0, 2))) && ok;
	ok = check("writeWidthSeven", throwsRange((): number => b.writeUIntLE(1, 0, off(7)))) && ok;
	ok = check("untouched", b.readUInt32LE(0) == 0x04030201 && b.readUInt8(7) == 8) && ok;

	ok = check("lastByte", b.readUInt8(7) == 8 && b.writeUInt8(255, 7) == 8 && b.readInt8(7) == -1) && ok;
	ok = check("edgeValues", b.writeInt16LE(-32768, 0) == 2 && b.readInt16LE(0) == -32768 && b.writeUInt32LE(4294967295, 4) == 8 && b.readUInt32LE(4) == 4294967295) && ok;
	ok = check("width6", b.writeUIntBE(281474976710655, 1, 6) == 7 && b.readUIntBE(1, 6) == 281474976710655) && ok;

	console.log(ok ? "range ok" : "range FAILED");
}

main();
