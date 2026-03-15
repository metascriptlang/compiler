// Buffer — Comprehensive Test Suite

import { Buffer } from "std/core/buffer";

// ===== Allocation =====

test "Buffer.alloc zero-fills" {
	const buf = Buffer.alloc(8);
	assert buf.length === 8;
	assert buf.get(0) === 0;
	assert buf.get(7) === 0;
}

test "Buffer.allocUnsafe has correct length" {
	const buf = Buffer.allocUnsafe(16);
	assert buf.length === 16;
}

test "Buffer.fromArray" {
	const buf = Buffer.fromArray([72, 101, 108, 108, 111]);
	assert buf.length === 5;
	assert buf.toString() === "Hello";
}

// ===== Creation / Conversion =====

test "Buffer.from utf8 string" {
	const buf = Buffer.from("Hello", "utf8");
	assert buf.length === 5;
	assert buf.get(0) === 72;
	assert buf.toString() === "Hello";
}

test "Buffer.from hex roundtrip" {
	const buf = Buffer.from("48656c6c6f", "hex");
	assert buf.toString() === "Hello";
	assert buf.toHex() === "48656c6c6f";
}

test "Buffer.from base64 roundtrip" {
	const buf = Buffer.from("SGVsbG8=", "base64");
	assert buf.toString() === "Hello";
	assert buf.toBase64() === "SGVsbG8=";
}

test "Buffer.fromBuffer deep copy" {
	const a = Buffer.from("abc", "utf8");
	const b = Buffer.fromBuffer(a);
	assert b.toString() === "abc";
	b.set(0, 88);
	assert a.get(0) === 97;
	assert b.get(0) === 88;
}

// ===== Byte Access =====

test "get and set" {
	const buf = Buffer.alloc(4);
	buf.set(0, 255);
	buf.set(3, 42);
	assert buf.get(0) === 255;
	assert buf.get(1) === 0;
	assert buf.get(3) === 42;
}

// ===== Operations =====

test "slice" {
	const buf = Buffer.from("Hello World", "utf8");
	const sliced = buf.slice(0, 5);
	assert sliced.toString() === "Hello";
	assert sliced.length === 5;
}

test "subarray alias" {
	const buf = Buffer.from("Hello World", "utf8");
	const sub = buf.subarray(6, 11);
	assert sub.toString() === "World";
}

test "copy" {
	const src = Buffer.from("Hello", "utf8");
	const dst = Buffer.alloc(5);
	const copied = src.copy(dst, 0, 0, 5);
	assert copied === 5;
	assert dst.toString() === "Hello";
}

test "fill" {
	const buf = Buffer.alloc(4);
	buf.fill(65, 0, 4);
	assert buf.toString() === "AAAA";
}

test "equals" {
	const a = Buffer.from("abc", "utf8");
	const b = Buffer.from("abc", "utf8");
	const c = Buffer.from("xyz", "utf8");
	assert a.equals(b);
	assert !a.equals(c);
}

test "compare" {
	const a = Buffer.from("abc", "utf8");
	const b = Buffer.from("abd", "utf8");
	assert a.compare(a) === 0;
	assert a.compare(b) < 0;
	assert b.compare(a) > 0;
}

test "static compare" {
	const a = Buffer.from("abc", "utf8");
	const b = Buffer.from("abd", "utf8");
	assert Buffer.compare(a, b) < 0;
}

test "concat" {
	const a = Buffer.from("Hello", "utf8");
	const b = Buffer.from(" World", "utf8");
	const c = Buffer.concat(a, b);
	assert c.toString() === "Hello World";
	assert c.length === 11;
}

// ===== Unsigned Integer Read/Write =====

test "uint8 roundtrip" {
	const buf = Buffer.alloc(1);
	buf.writeUInt8(200, 0);
	assert buf.readUInt8(0) === 200;
}

test "uint16 LE/BE roundtrip" {
	const buf = Buffer.alloc(4);
	buf.writeUInt16LE(0x1234, 0);
	buf.writeUInt16BE(0x5678, 2);
	assert buf.readUInt16LE(0) === 0x1234;
	assert buf.readUInt16BE(2) === 0x5678;
}

test "uint32 LE/BE roundtrip" {
	const buf = Buffer.alloc(8);
	buf.writeUInt32LE(0x12345678, 0);
	buf.writeUInt32BE(0xDEADBEEF, 4);
	assert buf.readUInt32LE(0) === 0x12345678;
	assert buf.readUInt32BE(4) === 0xDEADBEEF;
}

// ===== Signed Integer Read/Write =====

test "int8 roundtrip with negative" {
	const buf = Buffer.alloc(2);
	buf.writeInt8(127, 0);
	buf.writeInt8(-128, 1);
	assert buf.readInt8(0) === 127;
	assert buf.readInt8(1) === -128;
}

test "int16 LE/BE roundtrip with negative" {
	const buf = Buffer.alloc(4);
	buf.writeInt16LE(-1234, 0);
	buf.writeInt16BE(-5678, 2);
	assert buf.readInt16LE(0) === -1234;
	assert buf.readInt16BE(2) === -5678;
}

test "int32 LE/BE roundtrip with negative" {
	const buf = Buffer.alloc(8);
	buf.writeInt32LE(-123456789, 0);
	buf.writeInt32BE(-987654321, 4);
	assert buf.readInt32LE(0) === -123456789;
	assert buf.readInt32BE(4) === -987654321;
}

// ===== Float/Double Read/Write =====

test "float LE roundtrip" {
	const buf = Buffer.alloc(4);
	buf.writeFloatLE(3.140000104904175, 0);
	const val = buf.readFloatLE(0);
	assert val > 3.13;
	assert val < 3.15;
}

test "float BE roundtrip" {
	const buf = Buffer.alloc(4);
	buf.writeFloatBE(1.0, 0);
	const val = buf.readFloatBE(0);
	assert val > 0.99;
	assert val < 1.01;
}

test "double LE roundtrip" {
	const buf = Buffer.alloc(8);
	buf.writeDoubleLE(3.141592653589793, 0);
	assert buf.readDoubleLE(0) === 3.141592653589793;
}

test "double BE roundtrip" {
	const buf = Buffer.alloc(8);
	buf.writeDoubleBE(2.718281828459045, 0);
	assert buf.readDoubleBE(0) === 2.718281828459045;
}

// ===== 64-bit Integer Read/Write =====

test "uint64 LE roundtrip" {
	const buf = Buffer.alloc(8);
	buf.writeBigUInt64LE(1234567890, 0);
	assert buf.readBigUInt64LE(0) === 1234567890;
}

test "int64 LE roundtrip with negative" {
	const buf = Buffer.alloc(8);
	buf.writeBigInt64LE(-1234567890, 0);
	assert buf.readBigInt64LE(0) === -1234567890;
}

// ===== Search =====

test "indexOf found" {
	const buf = Buffer.fromArray([1, 2, 3, 4, 5]);
	assert buf.indexOf(3, 0) === 2;
}

test "indexOf not found" {
	const buf = Buffer.fromArray([1, 2, 3]);
	assert buf.indexOf(99, 0) === -1;
}

test "lastIndexOf" {
	const buf = Buffer.fromArray([1, 2, 3, 2, 1]);
	assert buf.lastIndexOf(2, 4) === 3;
}

test "includes" {
	const buf = Buffer.fromArray([10, 20, 30]);
	assert buf.includes(20, 0);
	assert !buf.includes(99, 0);
}

// ===== Byte Swap / Reverse =====

test "swap16" {
	const buf = Buffer.fromArray([0x01, 0x02, 0x03, 0x04]);
	buf.swap16();
	assert buf.get(0) === 0x02;
	assert buf.get(1) === 0x01;
	assert buf.get(2) === 0x04;
	assert buf.get(3) === 0x03;
}

test "swap32" {
	const buf = Buffer.fromArray([0x01, 0x02, 0x03, 0x04]);
	buf.swap32();
	assert buf.get(0) === 0x04;
	assert buf.get(1) === 0x03;
	assert buf.get(2) === 0x02;
	assert buf.get(3) === 0x01;
}

test "reverse" {
	const buf = Buffer.fromArray([1, 2, 3, 4, 5]);
	buf.reverse();
	assert buf.get(0) === 5;
	assert buf.get(1) === 4;
	assert buf.get(4) === 1;
}

// ===== Validation =====

test "isAscii" {
	const ascii = Buffer.from("Hello", "utf8");
	assert Buffer.isAscii(ascii);
}

test "isUtf8 valid" {
	const utf8 = Buffer.from("Hello", "utf8");
	assert Buffer.isUtf8(utf8);
}

test "isUtf8 invalid" {
	const bad = Buffer.fromArray([0xFF, 0xFE]);
	assert !Buffer.isUtf8(bad);
}
