import { sha256 } from "std/crypto/sha256";
import { isEdwardsPoint } from "std/crypto/ed25519/point";
import { Pubkey, pubkeyOf } from "./pubkey";
import { ProgramError } from "./error";

export struct ProgramAddress {
	key: Pubkey;
	bump: uint8;
}

const MAX_SEEDS: int32 = 16;
const MAX_SEED_LENGTH: int32 = 32;

export function derivedAddressOf(seeds: uint8[][], program: Pubkey): Result<ProgramAddress, ProgramError> {
	if (seeds.length > MAX_SEEDS - 1) { return Result.err(ProgramError.maxSeedLengthExceeded()); }
	let preimage: uint8[] = [];
	for (const seed of seeds) {
		if (seed.length > MAX_SEED_LENGTH) { return Result.err(ProgramError.maxSeedLengthExceeded()); }
		for (const byte of seed) { preimage.push(byte); }
	}
	const bumpAt = preimage.length;
	preimage.push(255);
	for (const byte of program.bytes) { preimage.push(byte); }
	for (const byte of "ProgramDerivedAddress".asBytes()) { preimage.push(byte); }
	for (let bump = 255; bump >= 1; bump--) {
		preimage[bumpAt] = bump as uint8;
		const digest = sha256(preimage);
		if (!isEdwardsPoint(digest.bytes)) {
			return Result.ok({ key: { bytes: digest.bytes }, bump: bump as uint8 });
		}
	}
	return Result.err(ProgramError.invalidSeeds());
}

function textBytes(text: string): uint8[] {
	let bytes: uint8[] = [];
	for (const byte of text.asBytes()) { bytes.push(byte); }
	return bytes;
}

function expectFound(seeds: uint8[][], program: string, key: string, bump: uint8): boolean {
	const id = Pubkey.parse(program);
	if (!id.ok) { return false; }
	const found = derivedAddressOf(seeds, id.value);
	if (!found.ok) { return false; }
	return found.value.bump == bump && found.value.key.toBase58() == key;
}

test "a literal seed derives the address and bump the client derives" {
	assert expectFound([textBytes("counter")], "B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32", "E9D2ze81hd8XieXvhPnH3EzwVcMH89sfo78jnjqGt9Gw", 255);
	assert expectFound([[]], "DHvAxn78uSi8YsUoVBVU13CWY24fDCecSRdd7u1tLtz2", "Ahf3f3saVbKHbfzk9NjqDJR37V3sSd2eA5ygb9ujgRCy", 253);
	assert expectFound([textBytes("vault"), [1, 2, 3]], "B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32", "2taaRBsfvwHz5PDLjF4n2iWqdNBBfjhjatBHzqpcSU1W", 254);
	assert expectFound([textBytes("s21")], "B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32", "7adBeyvsCKCUoq389WiMTZDVGXHoZaRqzNvSe7zxiFwD", 248);
}

test "more than fifteen seeds or a seed over 32 bytes is the runtime's refusal" {
	const program = pubkeyOf("B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32");
	const sixteen: uint8[][] = [[], [], [], [], [], [], [], [], [], [], [], [], [], [], [], []];
	const refused = ProgramError.maxSeedLengthExceeded().code;
	const tooMany = derivedAddressOf(sixteen, program);
	assert !tooMany.ok && tooMany.error.code == refused;
	const long = derivedAddressOf([textBytes("0123456789abcdef0123456789abcdefX")], program);
	assert !long.ok && long.error.code == refused;
	const fifteen: uint8[][] = [[], [], [], [], [], [], [], [], [], [], [], [], [], [], []];
	assert derivedAddressOf(fifteen, program).ok;
}

test "the derivation runs at compile time" {
	const bump = @comptime {
		const found = derivedAddressOf([textBytes("counter")], pubkeyOf("B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32"));
		return found.ok ? found.value.bump : 0;
	};
	assert bump == 255;
}
