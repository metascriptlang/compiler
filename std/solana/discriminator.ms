import { sha256 } from "std/crypto/sha256";

export struct Discriminator {
	bytes: uint8[8];
}

function isUpper(code: int32): boolean {
	return code >= 65 && code <= 90;
}

function isLowerOrDigit(code: int32): boolean {
	return (code >= 97 && code <= 122) || (code >= 48 && code <= 57);
}

export function snakeCase(name: string): string {
	let text = "";
	for (let i = 0; i < name.length; i++) {
		const code = name.charCodeAt(i);
		if (isUpper(code)) {
			const afterLower = i > 0 && isLowerOrDigit(name.charCodeAt(i - 1));
			const endsAcronym = i > 0 && isUpper(name.charCodeAt(i - 1)) &&
				i + 1 < name.length && isLowerOrDigit(name.charCodeAt(i + 1));
			if (afterLower || endsAcronym) { text += "_"; }
			text += String.fromCharCode(code + 32);
		} else {
			text += name.slice(i, i + 1);
		}
	}
	return text;
}

export function discriminatorOf(preimage: string): Discriminator {
	const digest = sha256(preimage.asBytes());
	let discriminator: Discriminator = { bytes: [0, 0, 0, 0, 0, 0, 0, 0] };
	for (let i = 0; i < 8; i++) { discriminator.bytes[i] = digest.bytes[i]; }
	return discriminator;
}

export function accountDiscriminator(typeName: string): Discriminator {
	return discriminatorOf("account:" + typeName);
}

export function instructionDiscriminator(instructionName: string): Discriminator {
	return discriminatorOf("global:" + snakeCase(instructionName));
}

export function eventDiscriminator(eventName: string): Discriminator {
	return discriminatorOf("event:" + eventName);
}

export function word(this discriminator: Discriminator): uint64 {
	let value: uint64 = 0;
	for (let i = 7; i >= 0; i--) {
		const byte: uint64 = discriminator.bytes[i] as uint64;
		value = (value << 8) | byte;
	}
	return value;
}

function expectBytes(discriminator: Discriminator, hex: string): boolean {
	const digits = "0123456789abcdef";
	for (let i = 0; i < 8; i++) {
		const high = digits.indexOf(hex.slice(i * 2, i * 2 + 1));
		const low = digits.indexOf(hex.slice(i * 2 + 1, i * 2 + 2));
		if (discriminator.bytes[i] != ((high * 16 + low) as uint8)) { return false; }
	}
	return true;
}

test "snake case follows the instruction names Anchor hashes" {
	assert snakeCase("Make") == "make";
	assert snakeCase("TakeAll") == "take_all";
	assert snakeCase("InitializeNFTMint") == "initialize_nft_mint";
	assert snakeCase("Step2Done") == "step2_done";
}

test "discriminators are the first eight bytes of Anchor's preimages" {
	assert expectBytes(accountDiscriminator("Escrow"), "1fd57bbbba16da9b");
	assert expectBytes(instructionDiscriminator("Make"), "8ae3e84ddfa660c5");
	assert expectBytes(instructionDiscriminator("TakeAll"), "50d0b2dc09f98cc7");
	assert expectBytes(instructionDiscriminator("InitializeNFTMint"), "8030aa2b2dbb8c04");
	assert expectBytes(eventDiscriminator("Made"), "f05b0741db7332e0");
}

test "a discriminator folds at compile time and reads as a little-endian word" {
	const folded: Discriminator = @comptime { return accountDiscriminator("Escrow"); };
	assert folded == accountDiscriminator("Escrow");
	assert folded.word() == 0x9bda16babb7bd51f;
}
