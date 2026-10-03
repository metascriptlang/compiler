export function leBytes(value: uint16): uint8[2] {
	return [(value & 0xff) as uint8, ((value >> 8) & 0xff) as uint8];
}

export function leBytes(value: uint32): uint8[4] {
	return [
		(value & 0xff) as uint8,
		((value >> 8) & 0xff) as uint8,
		((value >> 16) & 0xff) as uint8,
		((value >> 24) & 0xff) as uint8,
	];
}

export function leBytes(value: uint64): uint8[8] {
	return [
		(value & 0xff) as uint8,
		((value >> 8) & 0xff) as uint8,
		((value >> 16) & 0xff) as uint8,
		((value >> 24) & 0xff) as uint8,
		((value >> 32) & 0xff) as uint8,
		((value >> 40) & 0xff) as uint8,
		((value >> 48) & 0xff) as uint8,
		((value >> 56) & 0xff) as uint8,
	];
}

test "leBytes writes each width least significant byte first" {
	const two = leBytes(0x0102 as uint16);
	assert two.length == 2;
	assert two[0] == 2 && two[1] == 1;
	const four = leBytes(0x01020304 as uint32);
	assert four[0] == 4 && four[1] == 3 && four[2] == 2 && four[3] == 1;
	const eight = leBytes(0x0102030405060708 as uint64);
	assert eight[0] == 8 && eight[3] == 5 && eight[4] == 4 && eight[7] == 1;
}

test "leBytes of the largest values fills every byte" {
	const all = leBytes(0xffffffffffffffff as uint64);
	for (let i = 0; i < 8; i++) { assert all[i] == 255; }
	const wide = leBytes(0xffffffff as uint32);
	for (let i = 0; i < 4; i++) { assert wide[i] == 255; }
	const zero = leBytes(0 as uint64);
	for (let i = 0; i < 8; i++) { assert zero[i] == 0; }
}
