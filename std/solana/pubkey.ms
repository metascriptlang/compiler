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

export function equals(this key: Pubkey, other: Pubkey): boolean {
	return key == other;
}

export function systemProgram(this typeof Pubkey): Pubkey {
	return Pubkey.zero();
}

export function tokenProgram(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"); };
}

export function token2022Program(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"); };
}

export function associatedTokenProgram(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL"); };
}

export function rentSysvar(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("SysvarRent111111111111111111111111111111111"); };
}

export function clockSysvar(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("SysvarC1ock11111111111111111111111111111111"); };
}

export function slotHashesSysvar(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("SysvarS1otHashes111111111111111111111111111"); };
}

export function instructionsSysvar(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("Sysvar1nstructions1111111111111111111111111"); };
}

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
	assert Pubkey.systemProgram().toBase58() == "11111111111111111111111111111111";
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
	if (parsed.ok) { assert Pubkey.clockSysvar() == parsed.value; }
	const associated = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
	assert Pubkey.associatedTokenProgram().toBase58() == associated;
}
