// @stdout: buffer surface ok

// Pins the Buffer byte-container surface as it behaves on the C backend
// (Buffer = string alias). The js backend must match these outputs exactly
// once std/core/buffer/index.jms lands.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function main(): void {
	let ok = true;

	// alloc is zero-filled; byteLength is the byte count.
	const z = Buffer.alloc(4);
	let zero = true;
	let i = 0;
	while (i < 4) { if (z.byteAt(i) != 0) { zero = false; } i += 1; }
	ok = check("allocZero", zero && z.byteLength == 4) && ok;

	// set / byteAt round-trip.
	const b = Buffer.alloc(4);
	b.set(0, 0x12); b.set(1, 0x34); b.set(2, 0x56); b.set(3, 0x78);
	ok = check("setByteAt", b.byteAt(0) == 0x12 && b.byteAt(3) == 0x78) && ok;

	// fromArray copies every element.
	const fa = Buffer.fromArray([1, 2, 255]);
	ok = check("fromArray", fa.byteLength == 3 && fa.byteAt(2) == 255) && ok;

	// hex round-trip.
	const fh = Buffer.fromString("deadbeef", "hex");
	ok = check("fromHex", fh.byteLength == 4 && fh.byteAt(0) == 0xde && fh.byteAt(3) == 0xef) && ok;
	ok = check("toHex", fh.toHex() == "deadbeef") && ok;

	// base64 round-trip.
	const fb = Buffer.fromArray([1, 2, 3]);
	ok = check("toBase64", fb.toBase64() == "AQID") && ok;
	const fb2 = Buffer.fromString("AQID", "base64");
	ok = check("fromBase64", fb2.byteLength == 3 && fb2.byteAt(0) == 1) && ok;

	// utf8 multibyte encode/decode.
	const fu = Buffer.fromString("é", "utf8");
	ok = check("utf8Bytes", fu.byteLength == 2 && fu.byteAt(0) == 0xc3 && fu.byteAt(1) == 0xa9) && ok;
	ok = check("utf8Decode", fu.toStringEncoded("utf8", 0, fu.byteLength) == "é") && ok;

	// endian reads over known bytes.
	const e = Buffer.alloc(4);
	e.set(0, 0x12); e.set(1, 0x34); e.set(2, 0x56); e.set(3, 0x78);
	ok = check("u16be", e.readUInt16BE(0) == 0x1234) && ok;
	ok = check("u16le", e.readUInt16LE(0) == 0x3412) && ok;
	ok = check("u32be", e.readUInt32BE(0) == 0x12345678) && ok;
	e.set(0, 255);
	ok = check("i8neg", e.readInt8(0) == -1) && ok;

	// variable-length reads.
	const e2 = Buffer.fromArray([0x01, 0x02]);
	ok = check("uBE2", e2.readUIntBE(0, 2) == 0x0102) && ok;
	ok = check("uLE2", e2.readUIntLE(0, 2) == 0x0201) && ok;

	// write/read round-trips at each width.
	const w = Buffer.alloc(8);
	w.writeUInt16BE(0xabcd, 0);
	ok = check("w16be", w.readUInt16BE(0) == 0xabcd) && ok;
	w.writeUInt32LE(0x12345678, 2);
	ok = check("w32le", w.readUInt32LE(2) == 0x12345678) && ok;
	w.writeInt16BE(-2, 0);
	ok = check("wI16be", w.readInt16BE(0) == -2) && ok;
	w.writeDoubleBE(3.14159, 0);
	ok = check("wDbe", w.readDoubleBE(0) == 3.14159) && ok;
	w.writeFloatLE(1.5, 0);
	ok = check("wFle", w.readFloatLE(0) == 1.5) && ok;

	// 64-bit read/write through the bigint carrier — exact beyond 2^53.
	const q = Buffer.alloc(8);
	q.set(7, 1);
	ok = check("u64le", q.readBigUInt64LE(0) == 72057594037927936n) && ok;
	const big = Buffer.alloc(16);
	big.writeBigUInt64LE(0xDEADBEEFCAFEBABEn, 0);
	big.writeBigUInt64BE(0x0102030405060708n, 8);
	ok = check("bigU64le", big.readBigUInt64LE(0).toString(16) == "deadbeefcafebabe") && ok;
	ok = check("bigU64be", big.readBigUInt64BE(8).toString(16) == "102030405060708") && ok;
	big.writeBigInt64LE(-1234567890123456789n, 0);
	ok = check("bigI64le", big.readBigInt64LE(0) == -1234567890123456789n) && ok;
	ok = check("bigI64be", big.readBigInt64BE(0) == -1477718879929115154n) && ok;

	// swap mutates pair-wise / word-wise in place.
	const s16 = Buffer.fromArray([0x12, 0x34, 0x56, 0x78]);
	s16.swap16();
	ok = check("swap16", s16.byteAt(0) == 0x34 && s16.byteAt(1) == 0x12) && ok;
	const s32 = Buffer.fromArray([1, 2, 3, 4]);
	s32.swap32();
	ok = check("swap32", s32.byteAt(0) == 4 && s32.byteAt(3) == 1) && ok;

	// reverse is in-place.
	const rv = Buffer.fromArray([1, 2, 3]);
	rv.bufReverse();
	ok = check("reverse", rv.byteAt(0) == 3 && rv.byteAt(2) == 1) && ok;

	// fill over [start, end).
	const fl = Buffer.alloc(4);
	fl.fill(9, 1, 3);
	ok = check("fill", fl.byteAt(0) == 0 && fl.byteAt(1) == 9 && fl.byteAt(2) == 9 && fl.byteAt(3) == 0) && ok;

	// single-byte search with explicit offset.
	const ix = Buffer.fromArray([1, 3, 3]);
	ok = check("indexOf", ix.indexOf(3, 0) == 1 && ix.indexOf(3, 2) == 2 && ix.indexOf(9, 0) == -1) && ok;
	ok = check("lastIndexOf", ix.lastIndexOf(3, 3) == 2) && ok;
	ok = check("includes", ix.includes(3, 0) && !ix.includes(9, 0)) && ok;

	// buffer-in-buffer search.
	const hay = Buffer.fromArray([1, 2, 3, 2, 3]);
	const needle = Buffer.fromArray([2, 3]);
	ok = check("indexOfBuffer", hay.indexOfBuffer(needle, 0) == 1 && hay.indexOfBuffer(needle, 3) == 3) && ok;
	ok = check("includesBuffer", hay.includesBuffer(needle, 0) && !hay.includesBuffer(Buffer.fromArray([9]), 0)) && ok;

	// concat / concatList.
	const c1 = Buffer.fromArray([1, 2]);
	const c2 = Buffer.fromArray([3]);
	const cc = Buffer.concat(c1, c2);
	ok = check("concat", cc.byteLength == 3 && cc.byteAt(2) == 3) && ok;
	const parts: Buffer[] = [c1, c2, c1];
	const cl = Buffer.concatList(parts);
	ok = check("concatList", cl.byteLength == 5 && cl.byteAt(4) == 2) && ok;

	// copyTo(src -> dst at targetStart from [sourceStart, sourceEnd)).
	const src = Buffer.fromArray([1, 2, 3, 4]);
	const dst = Buffer.alloc(4);
	src.copyTo(dst, 1, 0, 2);
	ok = check("copyTo", dst.byteAt(1) == 1 && dst.byteAt(2) == 2 && dst.byteAt(0) == 0) && ok;

	// copyTo returns bytes actually copied, clamped like the C runtime.
	ok = check("copyToReturn", src.copyTo(Buffer.alloc(8), 2, 0, 4) == 4) && ok;
	ok = check("copyToSrcClamp", src.copyTo(Buffer.alloc(8), 0, 1, 99) == 3) && ok;
	const cpTight = Buffer.alloc(3);
	ok = check("copyToDstClamp", src.copyTo(cpTight, 1, 0, 4) == 2 && cpTight.byteAt(1) == 1) && ok;
	ok = check("copyToEmpty", src.copyTo(cpTight, 0, 3, 3) == 0) && ok;
	ok = check("copyToNegClamp", src.copyTo(Buffer.alloc(4), -5, -5, 2) == 2) && ok;

	// encoding-aware write returns bytes written.
	const wr = Buffer.alloc(4);
	const wrote = wr.write("AB", 0, 2, "binary");
	ok = check("write", wrote == 2 && wr.byteAt(0) == 65 && wr.byteAt(1) == 66) && ok;

	// compare / classification.
	ok = check("compare", Buffer.compare(Buffer.fromArray([1]), Buffer.fromArray([2])) < 0 &&
		Buffer.compare(Buffer.fromArray([1]), Buffer.fromArray([1])) == 0) && ok;
	ok = check("isAscii", Buffer.isAscii(Buffer.fromArray([1, 2])) && !Buffer.isAscii(Buffer.fromArray([0x80]))) && ok;
	ok = check("isUtf8", Buffer.isUtf8(Buffer.fromArray([0xc3, 0xa9])) && !Buffer.isUtf8(Buffer.fromArray([0x80]))) && ok;
	ok = check("isBufferEncoding", Buffer.isBufferEncoding("hex") && !Buffer.isBufferEncoding("bogus")) && ok;

	if (!ok) { console.log("buffer surface FAILED"); return; }
	console.log("buffer surface ok");
}

main();
