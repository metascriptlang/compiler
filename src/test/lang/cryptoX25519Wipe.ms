import { wipeBytes } from "../../../std/crypto/x25519/wipe";

test "X25519 wipe clears exactly the requested interior bytes" {
	let bytes: uint8[8] = [0x31, 0x42, 0x53, 0x64, 0x75, 0x86, 0x97, 0xa8];
	const data = bytes as Span<uint8> as Ptr<uint8>;
	wipeBytes(data + 2, 3);
	assert bytes[0] == 0x31 && bytes[1] == 0x42;
	assert bytes[2] == 0 && bytes[3] == 0 && bytes[4] == 0;
	assert bytes[5] == 0x86 && bytes[6] == 0x97 && bytes[7] == 0xa8;
}

test "X25519 zero-length wipe preserves guard bytes" {
	let bytes: uint8[3] = [0x31, 0x42, 0x53];
	const data = bytes as Span<uint8> as Ptr<uint8>;
	wipeBytes(data + 1, 0);
	assert bytes[0] == 0x31 && bytes[1] == 0x42 && bytes[2] == 0x53;
}

test "X25519 wipe clears a full byte region" {
	let bytes: uint8[4] = [1, 2, 3, 4];
	wipeBytes(bytes as Span<uint8> as Ptr<uint8>, 4);
	for (const byte of bytes) { assert byte == 0; }
}
