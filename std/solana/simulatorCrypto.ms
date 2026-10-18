import { msSolLoadU8, msSolLoadU64, msSolStoreU8 } from "./memory";
import { sha256 } from "std/crypto/sha256";
import { isEdwardsPoint } from "std/crypto/ed25519/point";
import { MAX_SEEDS, NO_BUMP, derivedDigest, findAddress, isOffCurve, seedsFit } from "./simulatorCryptoCore";

extern function msSolHostRaise(code: uint64, text: string): void;

const REFUSED: uint64 = 0xffffffffffffffff;
const NOT_SIMULATED: uint64 = 0xfffffffffffffffe;
const SEED_TOO_LONG: string = "Length of the seed is too long for address generation";

function readBytes(address: uint64, length: uint64): uint8[] {
	let bytes: uint8[] = [];
	for (let i: uint64 = 0; i < length; i++) { bytes.push(msSolLoadU8(address + i)); }
	return bytes;
}

function writeBytes(address: uint64, bytes: Readonly<Span<uint8>>): void {
	for (let i = 0; i < bytes.length; i++) { msSolStoreU8(address + (i as uint64), bytes[i]); }
}

function joinSlices(table: uint64, count: uint64): uint8[] {
	let joined: uint8[] = [];
	for (let i: uint64 = 0; i < count; i++) {
		const entry = table + i * 16;
		const part = readBytes(msSolLoadU64(entry), msSolLoadU64(entry + 8));
		for (let j = 0; j < part.length; j++) { joined.push(part[j]); }
	}
	return joined;
}

function sliceLengths(table: uint64, count: uint64): uint64[] {
	let lengths: uint64[] = [];
	for (let i: uint64 = 0; i < count; i++) { lengths.push(msSolLoadU64(table + i * 16 + 8)); }
	return lengths;
}

function seedsOverflow(table: uint64, count: uint64): boolean {
	if (count > MAX_SEEDS) { return true; }
	return !seedsFit(count, sliceLengths(table, count));
}

@exportName("msSolHostSha256")
export function msSolHostSha256(slices: uint64, count: uint64, out: uint64): uint64 {
	writeBytes(out, sha256(joinSlices(slices, count)).bytes);
	return 0;
}

@exportName("msSolHostCurveValidatePoint")
export function msSolHostCurveValidatePoint(curve: uint64, point: uint64, result: uint64): uint64 {
	if (curve == 1) {
		msSolHostRaise(NOT_SIMULATED, "sol_curve_validate_point: the ristretto curve (1) is not simulated");
		return 1;
	}
	if (curve != 0) {
		msSolHostRaise(REFUSED, "ProgramFailedToComplete: sol_curve_validate_point: InvalidAttribute");
		return 1;
	}
	return isEdwardsPoint(readBytes(point, 32)) ? 0 : 1;
}

@exportName("msSolHostCreateProgramAddress")
export function msSolHostCreateProgramAddress(seeds: uint64, count: uint64, programId: uint64, out: uint64): uint64 {
	if (seedsOverflow(seeds, count)) {
		msSolHostRaise(REFUSED, "ProgramFailedToComplete: sol_create_program_address: " + SEED_TOO_LONG);
		return 1;
	}
	const digest = derivedDigest(joinSlices(seeds, count), NO_BUMP, readBytes(programId, 32));
	if (!isOffCurve(digest)) { return 1; }
	writeBytes(out, digest.bytes);
	return 0;
}

@exportName("msSolHostTryFindProgramAddress")
export function msSolHostTryFindProgramAddress(seeds: uint64, count: uint64, programId: uint64, out: uint64, bumpOut: uint64): uint64 {
	if (seedsOverflow(seeds, count)) {
		msSolHostRaise(REFUSED, "ProgramFailedToComplete: sol_try_find_program_address: " + SEED_TOO_LONG);
		return 1;
	}
	if (count + 1 > MAX_SEEDS) { return 1; }
	const found = findAddress(joinSlices(seeds, count), readBytes(programId, 32));
	if (!found.found) { return 1; }
	writeBytes(out, found.digest.bytes);
	msSolStoreU8(bumpOut, found.bump);
	return 0;
}

@exportName("msSolHostDeriveAddress")
export function msSolHostDeriveAddress(seeds: uint64, count: uint64, bump: uint64, programId: uint64, out: uint64): uint64 {
	const hasBump = bump != 0;
	if (count + (hasBump ? 1 : 0) > MAX_SEEDS) { return 0; }
	const digest = derivedDigest(joinSlices(seeds, count), hasBump ? msSolLoadU8(bump) as int32 : NO_BUMP, readBytes(programId, 32));
	writeBytes(out, digest.bytes);
	return isOffCurve(digest) ? 1 : 0;
}
