export function accountReadUnsigned(bytes: Readonly<Span<uint8>>, offset: int32, width: int32): uint64 {
	let value: uint64 = 0;
	for (let i = width - 1; i >= 0; i -= 1) {
		value = (value << 8) | (bytes[offset + i] as uint64);
	}
	return value;
}

export function accountReadSigned(bytes: Readonly<Span<uint8>>, offset: int32, width: int32): int64 {
	let value = accountReadUnsigned(bytes, offset, width);
	if (width < 8 && (bytes[offset + width - 1] & 0x80) != 0) {
		value |= (0xffffffffffffffff as uint64) << ((width * 8) as uint64);
	}
	return value as int64;
}

export function accountWriteUnsigned(bytes: Span<uint8>, offset: int32, width: int32, value: uint64): void {
	for (let i = 0; i < width; i += 1) {
		bytes[offset + i] = ((value >> ((i * 8) as uint64)) & 255) as uint8;
	}
}

export function accountEnumBits(value: int32, width: int32): uint64 {
	const bits = (value as int64) as uint64;
	return width == 4 ? bits & 0xffffffff : bits & (((1 as uint64) << ((width * 8) as uint64)) - 1);
}

export function accountValueFromBits<T, U>(value: U): T { return value as T; }

test "codec scalar words retain all uint64 bits and sign-extend narrow signed values" {
	let bytes: uint8[8] = [0, 0, 0, 0, 0, 0, 0, 0];
	accountWriteUnsigned(bytes, 0, 8, 0xffffffffffffffff);
	assert accountReadUnsigned(bytes, 0, 8) == 0xffffffffffffffff;
	assert accountReadSigned(bytes, 0, 8) == -1;
	accountWriteUnsigned(bytes, 0, 8, 0x8000000000000000);
	assert accountReadUnsigned(bytes, 0, 8) == 0x8000000000000000;
	accountWriteUnsigned(bytes, 0, 8, 0);
	assert accountReadUnsigned(bytes, 0, 8) == 0;
	bytes[0] = 255;
	assert accountReadSigned(bytes, 0, 1) == -1;
	bytes[1] = 128;
	assert accountReadSigned(bytes, 0, 2) == -32513;
	bytes[2] = 0;
	bytes[3] = 128;
	assert accountReadSigned(bytes, 0, 4) == -2147450625;
}
