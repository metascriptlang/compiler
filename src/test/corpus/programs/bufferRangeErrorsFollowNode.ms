// @stdout: read 2^32 threw RangeError The value of "offset" is out of range. It must be >= 0 and <= 7. Received 4294967296
// @stdout: read 2^32+1 threw RangeError The value of "offset" is out of range. It must be >= 0 and <= 7. Received 4_294_967_297
// @stdout: read 5e9 threw RangeError The value of "offset" is out of range. It must be >= 0 and <= 7. Received 5_000_000_000
// @stdout: read -5e9 threw RangeError The value of "offset" is out of range. It must be >= 0 and <= 7. Received -5_000_000_000
// @stdout: read 1e21 threw RangeError The value of "offset" is out of range. It must be >= 0 and <= 7. Received 1e_+21
// @stdout: read -123456789012 threw RangeError The value of "offset" is out of range. It must be >= 0 and <= 4. Received -123_456_789_012
// @stdout: write uint32 5e9 threw RangeError The value of "value" is out of range. It must be >= 0 and <= 4294967295. Received 5_000_000_000
// @stdout: write int32 -5e9 threw RangeError The value of "value" is out of range. It must be >= -2147483648 and <= 2147483647. Received -5_000_000_000
// @stdout: write text offset 5e9 threw RangeError The value of "offset" is out of range. It must be >= 0 && <= 8. Received 5_000_000_000
// @stdout: write text length -5e9 threw RangeError The value of "length" is out of range. It must be >= 0 && <= 8. Received -5_000_000_000
// @stdout: byteLength 5e9 threw RangeError The value of "byteLength" is out of range. It must be >= 1 and <= 6. Received 5_000_000_000
// @stdout: value before offset uint16 threw RangeError The value of "value" is out of range. It must be >= 0 and <= 65535. Received 70000
// @stdout: value before offset uint32 threw RangeError The value of "value" is out of range. It must be >= 0 and <= 4294967295. Received 5_000_000_000
// @stdout: value before offset int16 threw RangeError The value of "value" is out of range. It must be >= -32768 and <= 32767. Received -40000
// @stdout: value before offset int32 threw RangeError The value of "value" is out of range. It must be >= -2147483648 and <= 2147483647. Received 3000000000
// @stdout: value before offset uint8 threw RangeError The value of "value" is out of range. It must be >= 0 and <= 255. Received 300
// @stdout: value before offset uintLE threw RangeError The value of "value" is out of range. It must be >= 0 and <= 16777215. Received -1
// @stdout: uintLE 6 too big threw RangeError The value of "value" is out of range. It must be >= 0 and < 2 ** 48. Received 281_474_976_710_656
// @stdout: uintBE 5 too big threw RangeError The value of "value" is out of range. It must be >= 0 and < 2 ** 40. Received 1_099_511_627_776
// @stdout: intLE 6 too small threw RangeError The value of "value" is out of range. It must be >= -(2 ** 47) and < 2 ** 47. Received -140_737_488_355_329
// @stdout: intBE 5 too big threw RangeError The value of "value" is out of range. It must be >= -(2 ** 39) and < 2 ** 39. Received 549_755_813_888
// @stdout: uintLE 4 too big threw RangeError The value of "value" is out of range. It must be >= 0 and <= 4294967295. Received 4294967296
// @stdout: intLE 3 too small threw RangeError The value of "value" is out of range. It must be >= -8388608 and <= 8388607. Received -8388609
// @stdout: big uint 2^64 threw RangeError The value of "value" is out of range. It must be >= 0n and < 2n ** 64n. Received 18_446_744_073_709_551_616n
// @stdout: big uint -1 threw RangeError The value of "value" is out of range. It must be >= 0n and < 2n ** 64n. Received -1n
// @stdout: big int -2^63-1 threw RangeError The value of "value" is out of range. It must be >= -(2n ** 63n) and < 2n ** 63n. Received -9_223_372_036_854_775_809n
// @stdout: big int 2^63 threw RangeError The value of "value" is out of range. It must be >= -(2n ** 63n) and < 2n ** 63n. Received 9_223_372_036_854_775_808n
// @stdout: big uint 2^32+1 offset threw RangeError The value of "offset" is out of range. It must be >= 0 and <= 0. Received 1
// @stdout: big int small out threw RangeError The value of "value" is out of range. It must be >= -(2n ** 63n) and < 2n ** 63n. Received 18_446_744_073_709_551_615n
// @stdout: big uint max 8 18446744073709551615 ffffffffffffffff
// @stdout: big int min 8 -9223372036854775808 8000000000000000
// @stdout: nan uint8 1 00ffffff00000000
// @stdout: nan int8 2 0000ffff00000000
// @stdout: nan uint16 4 0000000000000000
// @stdout: nan int32 8 0000000000000000
// @stdout: nan uintLE 7 00000000000000bf
// @stdout: nan intBE 3 000000000000f0bf
// @stdout: fraction uint8 1 7
// @stdout: byteAt 4 -1 -1 -1
// @stdout: byteAt sum 9

function failure(e: unknown): string {
	const kind = e instanceof TypeError ? "TypeError" : e instanceof RangeError ? "RangeError" : "Error";
	return `${kind} ${(e as Error).message}`;
}

function attempt(label: string, call: () => string): void {
	try {
		console.log(`${label} ${call()}`);
	} catch (e) {
		console.log(`${label} threw ${failure(e)}`);
	}
}

const b = Buffer.alloc(8);
const at = (n: number): number => n;

attempt("read 2^32", () => `${b.readUInt8(at(4294967296))}`);
attempt("read 2^32+1", () => `${b.readUInt8(at(4294967297))}`);
attempt("read 5e9", () => `${b.readUInt8(at(5e9))}`);
attempt("read -5e9", () => `${b.readUInt8(at(-5e9))}`);
attempt("read 1e21", () => `${b.readUInt8(at(1e21))}`);
attempt("read -123456789012", () => `${b.readInt32BE(at(-123456789012))}`);
attempt("write uint32 5e9", () => `${b.writeUInt32LE(at(5e9), 0)}`);
attempt("write int32 -5e9", () => `${b.writeInt32LE(at(-5e9), 0)}`);
attempt("write text offset 5e9", () => `${b.write("x", at(5e9), 1, "utf8")}`);
attempt("write text length -5e9", () => `${b.write("x", 0, at(-5e9), "utf8")}`);
attempt("byteLength 5e9", () => `${b.readUIntLE(0, at(5e9))}`);

attempt("value before offset uint16", () => `${b.writeUInt16BE(at(70000), 99)}`);
attempt("value before offset uint32", () => `${b.writeUInt32LE(at(5e9), 99)}`);
attempt("value before offset int16", () => `${b.writeInt16LE(at(-40000), 99)}`);
attempt("value before offset int32", () => `${b.writeInt32BE(at(3e9), 99)}`);
attempt("value before offset uint8", () => `${b.writeUInt8(at(300), 99)}`);
attempt("value before offset uintLE", () => `${b.writeUIntLE(at(-1), 99, 3)}`);

attempt("uintLE 6 too big", () => `${b.writeUIntLE(at(281474976710656), 0, 6)}`);
attempt("uintBE 5 too big", () => `${b.writeUIntBE(at(1099511627776), 0, 5)}`);
attempt("intLE 6 too small", () => `${b.writeIntLE(at(-140737488355329), 0, 6)}`);
attempt("intBE 5 too big", () => `${b.writeIntBE(at(549755813888), 0, 5)}`);
attempt("uintLE 4 too big", () => `${b.writeUIntLE(at(4294967296), 0, 4)}`);
attempt("intLE 3 too small", () => `${b.writeIntLE(at(-8388609), 0, 3)}`);

attempt("big uint 2^64", () => `${b.writeBigUInt64LE(18446744073709551616n, 0)}`);
attempt("big uint -1", () => `${b.writeBigUInt64BE(-1n, 0)}`);
attempt("big int -2^63-1", () => `${b.writeBigInt64LE(-9223372036854775809n, 0)}`);
attempt("big int 2^63", () => `${b.writeBigInt64BE(9223372036854775808n, 0)}`);
attempt("big uint 2^32+1 offset", () => `${b.writeBigUInt64LE(4294967297n, at(1))}`);
attempt("big int small out", () => `${b.writeBigInt64LE(-4294967297n, 0)} ${b.writeBigInt64LE(18446744073709551615n, 0)}`);
attempt("big uint max", () => `${b.writeBigUInt64LE(18446744073709551615n, 0)} ${b.readBigUInt64LE(0)} ${b.toHex()}`);
attempt("big int min", () => `${b.writeBigInt64BE(-9223372036854775808n, 0)} ${b.readBigInt64BE(0)} ${b.toHex()}`);

attempt("nan uint8", () => {
	b.writeUInt32LE(0xffffffff, 0);
	return `${b.writeUInt8(at(NaN), 0)} ${b.toHex()}`;
});
attempt("nan int8", () => `${b.writeInt8(at(NaN), 1)} ${b.toHex()}`);
attempt("nan uint16", () => `${b.writeUInt16BE(at(NaN), 2)} ${b.toHex()}`);
attempt("nan int32", () => `${b.writeInt32LE(at(NaN), 4)} ${b.toHex()}`);
attempt("nan uintLE", () => {
	b.writeDoubleLE(-1, 0);
	return `${b.writeUIntLE(at(NaN), 1, 6)} ${b.toHex()}`;
});
attempt("nan intBE", () => {
	b.writeDoubleLE(-1, 0);
	return `${b.writeIntBE(at(NaN), 0, 3)} ${b.toHex()}`;
});
attempt("fraction uint8", () => `${b.writeUInt8(at(7.9), 0)} ${b.readUInt8(0)}`);

const four = Buffer.fromArray([1, 2, 3, 4]);
attempt("byteAt", () => `${four.byteAt(at(3))} ${four.byteAt(at(4))} ${four.byteAt(at(-1))} ${four.byteAt(at(99))}`);
attempt("byteAt sum", () => {
	let sum = 0;
	for (let i = 0; i <= four.length; i++) sum += four.byteAt(i);
	return `${sum}`;
});
