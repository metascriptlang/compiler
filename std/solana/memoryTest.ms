import { SeedSlice, SignerSeeds } from "./addressTables";
import {
	msSolCompare,
	msSolCopy,
	msSolFill,
	msSolLoadU16,
	msSolLoadU32,
	msSolLoadU64,
	msSolLoadU8,
	msSolSeedsAddress,
	msSolSignersAddress,
	msSolSpanAddress,
	msSolStoreU16,
	msSolStoreU32,
	msSolStoreU64,
	msSolStoreU8,
	msSolStringAddress,
	msSolStringLength,
	msSolTableAddress,
	msSolWordsAddress,
} from "./memory";
import { msSolHostSha256, msSolHostTryFindProgramAddress } from "./simulatorCrypto";
import { findAddress } from "./simulatorCryptoCore";
import { pubkeyOf } from "./pubkey";
import { sha256 } from "std/crypto/sha256";

function addressOf(bytes: Readonly<Span<uint8>>): uint64 {
	return msSolSpanAddress(bytes);
}

function textBytes(text: string): uint8[] {
	let bytes: uint8[] = [];
	for (let i = 0; i < text.length; i++) { bytes.push(text.charCodeAt(i) as uint8); }
	return bytes;
}

test "a fixed byte buffer reads back what an address stored, at every width" {
	let buffer: uint8[16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	const at = addressOf(buffer);
	msSolStoreU8(at, 0xab);
	msSolStoreU16(at + 2, 0x1234);
	msSolStoreU32(at + 4, 0xdeadbeef);
	msSolStoreU64(at + 8, 0x0102030405060708);
	assert buffer[0] == 0xab && buffer[2] == 0x34 && buffer[3] == 0x12;
	assert buffer[4] == 0xef && buffer[7] == 0xde && buffer[8] == 8 && buffer[15] == 1;
	assert msSolLoadU8(at) == 0xab && msSolLoadU16(at + 2) == 0x1234;
	assert msSolLoadU32(at + 4) == 0xdeadbeef && msSolLoadU64(at + 8) == 0x0102030405060708;
}

test "writing the span shows through the address, and taking the address twice names the same bytes" {
	let buffer: uint8[8] = [0, 0, 0, 0, 0, 0, 0, 0];
	const first = addressOf(buffer);
	buffer[3] = 0x7f;
	assert msSolLoadU8(first + 3) == 0x7f;
	const second = addressOf(buffer);
	assert first == second;
	msSolStoreU8(second + 5, 9);
	assert buffer[5] == 9;
}

test "a word array is read as little-endian bytes and written through byte stores" {
	let words: uint64[2] = [0x0807060504030201, 0];
	const at = msSolWordsAddress(words);
	assert msSolLoadU8(at) == 1 && msSolLoadU8(at + 7) == 8 && msSolLoadU32(at + 4) == 0x08070605;
	msSolStoreU64(at + 8, 0xfffffffffffffffe);
	assert words[1] == 0xfffffffffffffffe;
	msSolStoreU8(at + 8, 0x11);
	assert words[1] == 0xffffffffffffff11;
}

test "an element address offsets by the element size, so a sub-span names later bytes" {
	let buffer: uint8[8] = [10, 11, 12, 13, 14, 15, 16, 17];
	const whole = addressOf(buffer);
	const tail = msSolSpanAddress(buffer[4..8]);
	assert tail == whole + 4;
	assert msSolLoadU8(tail) == 14;
}

test "a seed table is read and written as 16-byte entries" {
	let table: SeedSlice[2] = [{ address: 111, length: 2 }, { address: 222, length: 3 }];
	const at = msSolTableAddress(table);
	assert msSolSeedsAddress(table) == at;
	assert msSolLoadU64(at) == 111 && msSolLoadU64(at + 8) == 2;
	assert msSolLoadU64(at + 16) == 222 && msSolLoadU64(at + 24) == 3;
	msSolStoreU64(at + 24, 77);
	msSolStoreU64(at + 16, 5);
	assert table[1].length == 77 && table[1].address == 5;
	table[0] = { address: 9, length: 8 };
	assert msSolLoadU64(at) == 9 && msSolLoadU64(at + 8) == 8;
}

test "a signer table shares the seed layout" {
	let signers: SignerSeeds[2] = [{ address: 1, length: 2 }, { address: 3, length: 4 }];
	const at = msSolSignersAddress(signers);
	assert msSolLoadU64(at + 16) == 3 && msSolLoadU64(at + 24) == 4;
	msSolStoreU64(at + 8, 6);
	assert signers[0].length == 6;
}

when (js) {
	import { msSolMetasAddress } from "./memory";

	struct Meta {
		key: uint64;
		writable: uint8;
		signer: uint8;
	}
}

test "an instruction account table holds the key word and the two flag bytes of each 16-byte entry" {
	when (js) {
		let metas: Meta[2] = [{ key: 4096, writable: 1, signer: 0 }, { key: 8192, writable: 0, signer: 1 }];
		const at = msSolMetasAddress(metas);
		assert msSolLoadU64(at) == 4096 && msSolLoadU8(at + 8) == 1 && msSolLoadU8(at + 9) == 0;
		assert msSolLoadU64(at + 16) == 8192 && msSolLoadU8(at + 24) == 0 && msSolLoadU8(at + 25) == 1;
		msSolStoreU8(at + 25, 0);
		msSolStoreU8(at + 24, 1);
		msSolStoreU64(at + 16, 12288);
		assert metas[1].signer == 0 && metas[1].writable == 1 && metas[1].key == 12288;
	}
}

test "copy, fill and compare work between tables and byte buffers" {
	let table: SeedSlice[2] = [{ address: 0x1122334455667788, length: 4 }, { address: 6, length: 7 }];
	let bytes: uint8[16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	msSolCopy(addressOf(bytes), msSolTableAddress(table), 16);
	assert bytes[0] == 0x88 && bytes[7] == 0x11 && bytes[8] == 4 && bytes[9] == 0;
	let into: SeedSlice[2] = [{ address: 0, length: 0 }, { address: 0, length: 0 }];
	msSolCopy(msSolTableAddress(into), msSolTableAddress(table), 32);
	assert into[0].address == 0x1122334455667788 && into[1].length == 7;
	msSolFill(addressOf(bytes), 0x5a, 5);
	assert bytes[4] == 0x5a && bytes[5] == 0x33;
	let other: uint8[16] = [0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	assert msSolCompare(addressOf(bytes), addressOf(other), 5) == 0;
	other[3] = 0x60;
	assert msSolCompare(addressOf(bytes), addressOf(other), 5) < 0;
	assert msSolCompare(addressOf(other), addressOf(bytes), 5) > 0;
	assert msSolCompare(addressOf(other), addressOf(bytes), 3) == 0;
}

test "a string's address names its UTF-8 bytes and its length counts bytes" {
	const text = "héllo";
	const at = msSolStringAddress(text);
	assert msSolStringLength(text) == 6;
	assert msSolLoadU8(at) == 0x68 && msSolLoadU8(at + 1) == 0xc3 && msSolLoadU8(at + 2) == 0xa9 && msSolLoadU8(at + 5) == 0x6f;
	assert msSolStringAddress(text) == at;
	assert msSolStringLength("abc") == 3 && msSolLoadU8(msSolStringAddress("abc") + 2) == 0x63;
}

test "the host sha256 over two seed slices is the digest of the joined bytes" {
	const first = textBytes("ab");
	const second = textBytes("cdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
	let table: SeedSlice[2] = [
		{ address: addressOf(first), length: first.length as uint64 },
		{ address: addressOf(second), length: second.length as uint64 },
	];
	let out: uint8[32] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	assert msSolHostSha256(msSolTableAddress(table), 2, addressOf(out)) == 0;
	const expected = sha256(textBytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
	for (let i = 0; i < 32; i++) { assert out[i] == expected.bytes[i]; }
	let one: SeedSlice[1] = [{ address: addressOf(first), length: 2 }];
	assert msSolHostSha256(msSolTableAddress(one), 1, addressOf(out)) == 0;
	const single = sha256(first);
	for (let i = 0; i < 32; i++) { assert out[i] == single.bytes[i]; }
}

test "the host program address search over spans gives the address and bump of the pure core" {
	const program = pubkeyOf("B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32");
	for (const seed of ["counter", "s21"]) {
		const seedBytes = textBytes(seed);
		let table: SeedSlice[1] = [{ address: addressOf(seedBytes), length: seedBytes.length as uint64 }];
		let out: uint8[32] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
		let bump: uint8[1] = [0];
		assert msSolHostTryFindProgramAddress(msSolTableAddress(table), 1, addressOf(program.bytes), addressOf(out), addressOf(bump)) == 0;
		const found = findAddress(seedBytes, program.bytes);
		assert bump[0] == found.bump;
		for (let i = 0; i < 32; i++) { assert out[i] == found.digest.bytes[i]; }
	}
}
