import { Sha256Digest, sha256, toHex } from "std/crypto/sha256";
import { Pubkey, pubkeyOf } from "./pubkey";
import { isEdwardsPoint } from "std/crypto/ed25519/point";

export const MAX_SEEDS: uint64 = 16;
export const MAX_SEED_LENGTH: uint64 = 32;
export const NO_BUMP: int32 = -1;

export struct FoundAddress {
	found: boolean;
	bump: uint8;
	digest: Sha256Digest;
}

export function seedsFit(count: uint64, lengths: Readonly<Span<uint64>>): boolean {
	if (count > MAX_SEEDS) { return false; }
	for (let i = 0; i < lengths.length; i++) {
		if (lengths[i] > MAX_SEED_LENGTH) { return false; }
	}
	return true;
}

export function derivedDigest(seeds: Readonly<Span<uint8>>, bump: int32, programId: Readonly<Span<uint8>>): Sha256Digest {
	let preimage: uint8[] = [];
	for (let i = 0; i < seeds.length; i++) { preimage.push(seeds[i]); }
	if (bump != NO_BUMP) { preimage.push(bump as uint8); }
	for (let i = 0; i < programId.length; i++) { preimage.push(programId[i]); }
	const marker = "ProgramDerivedAddress".asBytes();
	for (let i = 0; i < marker.length; i++) { preimage.push(marker[i]); }
	return sha256(preimage);
}

export function isOffCurve(digest: Sha256Digest): boolean {
	return !isEdwardsPoint(digest.bytes);
}

export function findAddress(seeds: Readonly<Span<uint8>>, programId: Readonly<Span<uint8>>): FoundAddress {
	let found: FoundAddress = { found: false, bump: 0, digest: sha256([]) };
	for (let bump: int32 = 255; bump >= 1; bump--) {
		const digest = derivedDigest(seeds, bump, programId);
		if (isOffCurve(digest)) {
			found.found = true;
			found.bump = bump as uint8;
			found.digest = digest;
			return found;
		}
	}
	return found;
}

function textBytes(text: string): uint8[] {
	let bytes: uint8[] = [];
	for (const byte of text.asBytes()) { bytes.push(byte); }
	return bytes;
}

function hexBytes(hex: string): uint8[] {
	let bytes: uint8[] = [];
	const digits = "0123456789abcdef";
	for (let i = 0; i + 1 < hex.length; i += 2) {
		const high = digits.indexOf(hex.slice(i, i + 1));
		const low = digits.indexOf(hex.slice(i + 1, i + 2));
		bytes.push((high * 16 + low) as uint8);
	}
	return bytes;
}

function foundMatches(seeds: uint8[], program: Pubkey, key: string, bump: uint8): boolean {
	const found = findAddress(seeds, program.bytes);
	const address: Pubkey = { bytes: found.digest.bytes };
	return found.found && found.bump == bump && address.toBase58() == key;
}

test "sha256 over joined seeds matches the NIST vectors the syscall hashes" {
	assert derivedDigest([], NO_BUMP, []).toHex() == sha256(textBytes("ProgramDerivedAddress")).toHex();
	assert sha256([]).toHex() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
	assert sha256(textBytes("abc")).toHex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	const twoBlocks = textBytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
	assert sha256(twoBlocks).toHex() == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
}

test "the curve check accepts the identity and the base point and refuses a y with no x" {
	assert isEdwardsPoint(hexBytes("0100000000000000000000000000000000000000000000000000000000000000"));
	assert isEdwardsPoint(hexBytes("5866666666666666666666666666666666666666666666666666666666666666"));
	assert !isEdwardsPoint(hexBytes("0200000000000000000000000000000000000000000000000000000000000000"));
}

test "a program address search finds the address and bump the client derives" {
	const counter = pubkeyOf("B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32");
	assert foundMatches(textBytes("counter"), counter, "E9D2ze81hd8XieXvhPnH3EzwVcMH89sfo78jnjqGt9Gw", 255);
	assert foundMatches([], pubkeyOf("DHvAxn78uSi8YsUoVBVU13CWY24fDCecSRdd7u1tLtz2"), "Ahf3f3saVbKHbfzk9NjqDJR37V3sSd2eA5ygb9ujgRCy", 253);
	assert foundMatches(textBytes("s21"), counter, "7adBeyvsCKCUoq389WiMTZDVGXHoZaRqzNvSe7zxiFwD", 248);
}

test "a derivation with an explicit bump is the search's answer and is off the curve" {
	const program = pubkeyOf("B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32").bytes;
	const found = findAddress(textBytes("s21"), program);
	const again = derivedDigest(textBytes("s21"), found.bump as int32, program);
	assert again.toHex() == found.digest.toHex();
	assert isOffCurve(again);
	assert !isOffCurve(derivedDigest(textBytes("s21"), 255, program));
}

test "seed limits count seeds and measure each seed" {
	assert seedsFit(16, [32, 0, 1]);
	assert !seedsFit(17, [1]);
	assert !seedsFit(2, [1, 33]);
	assert seedsFit(0, []);
}
