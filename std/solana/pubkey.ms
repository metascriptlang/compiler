export struct Pubkey {
	bytes: uint8[32];
}

export enum PubkeyError {
	InvalidCharacter,
	WrongLength,
}

function base58Digit(code: int32): int32 {
	const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
	for (let i = 0; i < 58; i++) {
		if (alphabet.charCodeAt(i) == code) { return i; }
	}
	return -1;
}

export function zero(this typeof Pubkey): Pubkey {
	return {
		bytes: [
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		],
	};
}

export function fromBytes(
	this typeof Pubkey,
	source: Readonly<Span<uint8>>,
): Result<Pubkey, PubkeyError> {
	if (source.length != 32) { return Result.err(PubkeyError.WrongLength); }
	let key = Pubkey.zero();
	for (let i = 0; i < 32; i++) { key.bytes[i] = source[i]; }
	return Result.ok(key);
}

export function parse(this typeof Pubkey, text: string): Result<Pubkey, PubkeyError> {
	let key = Pubkey.zero();
	let leadingOnes = 0;
	let counting = true;
	for (let c = 0; c < text.length; c++) {
		const digit = base58Digit(text.charCodeAt(c));
		if (digit < 0) { return Result.err(PubkeyError.InvalidCharacter); }
		if (counting && digit == 0) {
			leadingOnes++;
		} else {
			counting = false;
		}
		let carry = digit as uint32;
		for (let i = 31; i >= 0; i--) {
			carry += (key.bytes[i] as uint32) * 58;
			key.bytes[i] = (carry & 0xff) as uint8;
			carry = carry >> 8;
		}
		if (carry != 0) { return Result.err(PubkeyError.WrongLength); }
	}
	let leadingZeroBytes = 0;
	while (leadingZeroBytes < 32 && key.bytes[leadingZeroBytes] == 0) { leadingZeroBytes++; }
	if (leadingZeroBytes != leadingOnes) { return Result.err(PubkeyError.WrongLength); }
	return Result.ok(key);
}

@comptime export function pubkeyOf(text: string): Pubkey {
	const parsed = Pubkey.parse(text);
	if (!parsed.ok) { unreachable; }
	return parsed.value;
}

export function toBase58(this key: Pubkey): string {
	const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
	let digits: uint8[44] = [
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	];
	let used = 0;
	for (let i = 0; i < 32; i++) {
		let carry = key.bytes[i] as uint32;
		for (let d = 0; d < used; d++) {
			carry += (digits[d] as uint32) << 8;
			digits[d] = (carry % 58) as uint8;
			carry = carry / 58;
		}
		while (carry > 0) {
			digits[used] = (carry % 58) as uint8;
			used++;
			carry = carry / 58;
		}
	}
	let text = "";
	for (let i = 0; i < 32 && key.bytes[i] == 0; i++) { text += "1"; }
	for (let d = used - 1; d >= 0; d--) {
		const at = digits[d] as int32;
		text += alphabet.slice(at, at + 1);
	}
	return text;
}

export function isZero(this key: Pubkey): boolean {
	return key == Pubkey.zero();
}

when (solana) {
	@include("runtime/solana/solana.h");

	extern function msSolLoadU64(address: uint64): uint64;
	extern function msSolSpanAddress(data: Readonly<Span<uint8>>): uint64;

	// The builtin struct `==` is a byte loop: 352 CU for equal keys, measured on LiteSVM 1.4.1.
	export function `==`(this left: Pubkey, right: Pubkey): boolean {
		const a = msSolSpanAddress(left.bytes);
		const b = msSolSpanAddress(right.bytes);
		return msSolLoadU64(a) == msSolLoadU64(b) &&
			msSolLoadU64(a + 8) == msSolLoadU64(b + 8) &&
			msSolLoadU64(a + 16) == msSolLoadU64(b + 16) &&
			msSolLoadU64(a + 24) == msSolLoadU64(b + 24);
	}
}

export function equals(this key: Pubkey, other: Pubkey): boolean {
	return key == other;
}

export const SYSTEM_PROGRAM_ID: Pubkey = pubkeyOf("11111111111111111111111111111111");
export const TOKEN_PROGRAM_ID: Pubkey = pubkeyOf("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
export const TOKEN_2022_PROGRAM_ID: Pubkey = pubkeyOf("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
export const ASSOCIATED_TOKEN_PROGRAM_ID: Pubkey = pubkeyOf("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
export const RENT_ID: Pubkey = pubkeyOf("SysvarRent111111111111111111111111111111111");
export const CLOCK_ID: Pubkey = pubkeyOf("SysvarC1ock11111111111111111111111111111111");
export const SLOTHASHES_ID: Pubkey = pubkeyOf("SysvarS1otHashes111111111111111111111111111");
export const INSTRUCTIONS_ID: Pubkey = pubkeyOf("Sysvar1nstructions1111111111111111111111111");

test "base58 round-trips a program id" {
	const text = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
	const parsed = Pubkey.parse(text);
	assert parsed.ok;
	if (parsed.ok) {
		assert parsed.value.bytes[0] == 6 && parsed.value.bytes[31] == 169;
		assert parsed.value.toBase58() == text;
	}
}

test "the System program is 32 ones and the zero key" {
	const parsed = Pubkey.parse("11111111111111111111111111111111");
	assert parsed.ok;
	if (parsed.ok) { assert parsed.value.isZero(); }
	assert SYSTEM_PROGRAM_ID == Pubkey.zero();
	assert SYSTEM_PROGRAM_ID.toBase58() == "11111111111111111111111111111111";
}

test "base58 refuses a character outside the alphabet and a key that is not 32 bytes" {
	const zeroLetter = Pubkey.parse("0okenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
	assert !zeroLetter.ok;
	if (!zeroLetter.ok) { assert zeroLetter.error == PubkeyError.InvalidCharacter; }
	const short = Pubkey.parse("2222");
	assert !short.ok;
	if (!short.ok) { assert short.error == PubkeyError.WrongLength; }
	const long = Pubkey.parse("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DATT");
	assert !long.ok;
}

test "compile-time ids equal the parsed ones" {
	const parsed = Pubkey.parse("SysvarC1ock11111111111111111111111111111111");
	assert parsed.ok;
	if (parsed.ok) { assert CLOCK_ID == parsed.value; }
	const associated = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
	assert ASSOCIATED_TOKEN_PROGRAM_ID.toBase58() == associated;
}

// pinocchio-token-0.6.0/src/lib.rs:14, pinocchio-associated-token-account-0.4.0/src/lib.rs:5, spl-token-2022-interface-2.1.0/src/lib.rs:25.
test "the program ids are the ones the reference declares" {
	assert SYSTEM_PROGRAM_ID == Pubkey.zero();
	assert SYSTEM_PROGRAM_ID.toBase58() == "11111111111111111111111111111111";
	assert TOKEN_PROGRAM_ID.toBase58() == "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
	assert TOKEN_2022_PROGRAM_ID.toBase58() == "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";
	assert ASSOCIATED_TOKEN_PROGRAM_ID.toBase58() == "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
}

// pinocchio-0.9.3/src/sysvars: clock.rs:13, rent.rs:15, instructions.rs:11, slot_hashes/mod.rs:28.
test "the sysvar ids are the bytes the reference declares" {
	const clock: Pubkey = { bytes: [
		6, 167, 213, 23, 24, 199, 116, 201, 40, 86, 99, 152, 105, 29, 94, 182,
		139, 94, 184, 163, 155, 75, 109, 92, 115, 85, 91, 33, 0, 0, 0, 0,
	] };
	const rent: Pubkey = { bytes: [
		6, 167, 213, 23, 25, 44, 92, 81, 33, 140, 201, 76, 61, 74, 241, 127,
		88, 218, 238, 8, 155, 161, 253, 68, 227, 219, 217, 138, 0, 0, 0, 0,
	] };
	const instructions: Pubkey = { bytes: [
		6, 167, 213, 23, 24, 123, 209, 102, 53, 218, 212, 4, 85, 253, 194, 192,
		193, 36, 198, 143, 33, 86, 117, 165, 219, 186, 203, 95, 8, 0, 0, 0,
	] };
	const slotHashes: Pubkey = { bytes: [
		6, 167, 213, 23, 25, 47, 10, 175, 198, 242, 101, 227, 251, 119, 204, 122,
		218, 130, 197, 41, 208, 190, 59, 19, 110, 45, 0, 85, 32, 0, 0, 0,
	] };
	assert CLOCK_ID == clock;
	assert RENT_ID == rent;
	assert INSTRUCTIONS_ID == instructions;
	assert SLOTHASHES_ID == slotHashes;
}
