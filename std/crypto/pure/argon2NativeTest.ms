import { Argon2Encoded, Argon2Mode, argon2Encode, argon2ModeName, argon2Problem, argon2Raw, argon2VerifyEncoded, argon2Words, argon2idHash, decodeArgon2, decodeArgon2id } from "./argon2";

function asciiBytes(s: string): uint8[] {
	const out = new Array<uint8>(s.length as int32);
	for (let i = 0; i < s.length; i++) out[i] = (s.charCodeAt(i) & 0xff) as uint8;
	return out;
}

const pw: uint8[] = asciiBytes("password");
const salt: uint8[] = asciiBytes("somesalt");

test "argon2Problem accepts minimum-valid parameters" {
	assert argon2Problem(1, 64, 1, 4, 8) == "";
	assert argon2Problem(1, 8, 1, 4, 8) == "";
}

test "argon2Problem rejects each boundary" {
	assert argon2Problem(1, 64, 1, 3, 8) == "Output is too short";
	assert argon2Problem(0, 64, 1, 4, 8) == "Time cost is too small";
	assert argon2Problem(1, 64, 0, 4, 8) == "Too few lanes";
	assert argon2Problem(1, 7, 1, 4, 8) == "Memory cost is too small";
	assert argon2Problem(1, 15, 2, 4, 8) == "Memory cost is too small";
	assert argon2Problem(1, 64, 1, 4, 7) == "Salt is too short";
}

test "argon2Words sizes lane-aligned block count" {
	assert argon2Words(8, 1) == 2048;
	assert argon2Words(64, 1) == 16384;
	assert argon2Words(64, 4) == 16384;
}

test "argon2id a4 t=1 m=8 p=1 four bytes match 6b7a947d" {
	const got = argon2idHash(new Array<uint32>(argon2Words(8, 1) as int32), pw, salt, 1, 8, 1, 0x13, 4);
	assert got[0] == 0x6b && got[1] == 0x7a && got[2] == 0x94 && got[3] == 0x7d;
}

test "argon2id a1 t=3 m=64 p=4 sixteen bytes match 773cbdd5..." {
	const got = argon2idHash(new Array<uint32>(argon2Words(64, 4) as int32), pw, salt, 3, 64, 4, 0x13, 16);
	assert got[0] == 0x77 && got[1] == 0x3c && got[2] == 0xbd && got[3] == 0xd5;
	assert got[4] == 0x91 && got[5] == 0x64 && got[6] == 0x9d && got[7] == 0xfd;
	assert got[8] == 0xc8 && got[9] == 0x41 && got[10] == 0x9f && got[11] == 0xfb;
	assert got[12] == 0x19 && got[13] == 0xe0 && got[14] == 0x12 && got[15] == 0x11;
}

test "argon2id t=2 m=64 p=2 twenty-four bytes match 350ac372... NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi" {
	const got = argon2idHash(new Array<uint32>(argon2Words(64, 2) as int32), pw, salt, 2, 64, 2, 0x13, 24);
	assert got[0] == 0x35 && got[1] == 0x0a && got[2] == 0xc3 && got[3] == 0x72;
	assert got[4] == 0x22 && got[5] == 0xf4 && got[6] == 0x36 && got[7] == 0xcc;
	assert got[8] == 0xb5 && got[9] == 0xc0 && got[10] == 0x97 && got[11] == 0x2f;
	assert got[12] == 0x1e && got[13] == 0xbd && got[14] == 0x3b && got[15] == 0xf6;
	assert got[16] == 0xb9 && got[17] == 0x58 && got[18] == 0xbf && got[19] == 0x20;
	assert got[20] == 0x71 && got[21] == 0x84 && got[22] == 0x13 && got[23] == 0x62;
}

function filled(length: int32, value: uint8): uint8[] {
	const out = new Array<uint8>(length);
	for (let i = 0; i < length; i++) out[i] = value;
	return out;
}

function sameBytes(got: Readonly<uint8[]>, want: Readonly<uint8[]>): boolean {
	if (got.length != want.length) return false;
	for (let i = 0; i < want.length; i++) {
		if (got[i] != want[i]) return false;
	}
	return true;
}

function rfcVector(mode: Argon2Mode): uint8[] {
	const raw = argon2Raw(filled(32, 0x01), filled(16, 0x02), 3, 32, 4, 32, mode, filled(8, 0x03), filled(12, 0x04));
	return raw.ok ? raw.value : [];
}

test "argon2d RFC 9106 5.1 with secret and ad" {
	assert sameBytes(rfcVector(Argon2Mode.Argon2d), [
		0x51, 0x2b, 0x39, 0x1b, 0x6f, 0x11, 0x62, 0x97, 0x53, 0x71, 0xd3, 0x09, 0x19, 0x73, 0x42, 0x94,
		0xf8, 0x68, 0xe3, 0xbe, 0x39, 0x84, 0xf3, 0xc1, 0xa1, 0x3a, 0x4d, 0xb9, 0xfa, 0xbe, 0x4a, 0xcb,
	]);
}

test "argon2i RFC 9106 5.2 with secret and ad" {
	assert sameBytes(rfcVector(Argon2Mode.Argon2i), [
		0xc8, 0x14, 0xd9, 0xd1, 0xdc, 0x7f, 0x37, 0xaa, 0x13, 0xf0, 0xd7, 0x7f, 0x24, 0x94, 0xbd, 0xa1,
		0xc8, 0xde, 0x6b, 0x01, 0x6d, 0xd3, 0x88, 0xd2, 0x99, 0x52, 0xa4, 0xc4, 0x67, 0x2b, 0x6c, 0xe8,
	]);
}

test "argon2id RFC 9106 5.3 with secret and ad" {
	assert sameBytes(rfcVector(Argon2Mode.Argon2id), [
		0x0d, 0x64, 0x0d, 0xf5, 0x8d, 0x78, 0x76, 0x6c, 0x08, 0xc0, 0x37, 0xa3, 0x4a, 0x8b, 0x53, 0xc9,
		0xd0, 0x1e, 0xf0, 0x45, 0x2d, 0x75, 0xb6, 0x5e, 0xb5, 0x25, 0x20, 0xe9, 0x6b, 0x01, 0xe6, 0x59,
	]);
}

test "argon2Raw refuses too small memory and salt with the reference message" {
	const smallMemory = argon2Raw(pw, salt, 1, 7, 1, 32);
	assert !smallMemory.ok && smallMemory.error == "Memory cost is too small";
	const shortSalt = argon2Raw(pw, asciiBytes("short"), 1, 64, 1, 32);
	assert !shortSalt.ok && shortSalt.error == "Salt is too short";
	assert !argon2Encode(pw, salt, 1, 15, 2, 32).ok;
}

test "argon2Encode t=2 m=64 p=2 gives the PHC string of the Zig vector" {
	const encoded = argon2Encode(pw, salt, 2, 64, 2, 24);
	assert encoded.ok;
	assert encoded.value == "$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi";
}

test "argon2 encoded roundtrip verifies the password and refuses another" {
	for (const mode of [Argon2Mode.Argon2d, Argon2Mode.Argon2i, Argon2Mode.Argon2id]) {
		const encoded = argon2Encode(pw, salt, 1, 32, 1, 16, mode);
		assert encoded.ok;
		assert encoded.value.startsWith("$" + argon2ModeName(mode) + "$v=19$m=32,t=1,p=1$");
		const fields = decodeArgon2(encoded.value);
		assert fields != null;
		const decoded = fields as Argon2Encoded;
		assert decoded.mode == mode && decoded.hash.length == 16 && sameBytes(decoded.salt, salt);
		assert argon2VerifyEncoded(encoded.value, pw);
		assert !argon2VerifyEncoded(encoded.value, asciiBytes("passwore"));
	}
}

test "argon2VerifyEncoded refuses malformed strings and parameters over the bounds" {
	const good = "$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi";
	assert argon2VerifyEncoded(good, pw);
	assert !argon2VerifyEncoded("", pw);
	assert !argon2VerifyEncoded("argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", pw);
	assert !argon2VerifyEncoded("$argon2x$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", pw);
	assert !argon2VerifyEncoded("$argon2id$v=19$m=64,t=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", pw);
	assert !argon2VerifyEncoded("$argon2id$v=19$m=064,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", pw);
	assert !argon2VerifyEncoded("$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBN!", pw);
	assert !argon2VerifyEncoded("$argon2id$v=18$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", pw);
	assert !argon2VerifyEncoded("$argon2id$v=19$m=64,t=2,p=2$c2FsdA$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", pw);
	assert !argon2VerifyEncoded(good, pw, { memoryCost: 32, timeCost: 12, parallelism: 16 });
	assert decodeArgon2id("$argon2i$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi") == null;
}

test "argon2idHash wipes the memory matrix it was given" {
	const memory = new Array<uint32>(argon2Words(32, 1) as int32);
	argon2idHash(memory, pw, salt, 1, 32, 1, 0x13, 16);
	let any: uint32 = 0;
	for (const word of memory) any |= word;
	assert any == 0;
}

test "argon2Raw refuses memory the matrix cannot index before allocating" {
	const huge = argon2Raw(pw, salt, 1, 8388608, 1, 32);
	assert !huge.ok && huge.error == "Memory allocation error";
	assert !argon2VerifyEncoded("$argon2id$v=19$m=8388608,t=1,p=1$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi", pw, { memoryCost: 8388608, timeCost: 12, parallelism: 16 });
}

test "base64 fields with a character outside ASCII are refused" {
	assert decodeArgon2("$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNé") == null;
}
