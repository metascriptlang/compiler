import { word } from "./discriminator";
import { ProgramError } from "./error";
import { Pubkey } from "./pubkey";
import { accountReadUnsigned, accountWriteUnsigned } from "./accountCodecScalars";
import { accountByteArray } from "./accountCodecKernel";
import { accountCodecFieldsValid, accountCodecRead, accountCodecSize, accountCodecValueValid, accountCodecWrite } from "./accountCodecMacro";

export function decode<T>(bytes: Readonly<Span<uint8>>, owner: Pubkey, expectedOwner: Pubkey): Result<T, ProgramError> {
	if (owner != expectedOwner) { return Result.err(ProgramError.accountOwnedByWrongProgram()); }
	return decode<T>(bytes);
}

/** Decodes account bytes only; this overload makes no claim about their owner. */
export function decode<T>(bytes: Readonly<Span<uint8>>): Result<T, ProgramError> {
	const size: int32 = accountCodecSize<T>();
	const discriminator = @comptime { return word(T.discriminator()); };
	if (bytes.length < 8) { return Result.err(ProgramError.accountDiscriminatorNotFound()); }
	if (accountReadUnsigned(bytes, 0, 8) != discriminator) {
		return Result.err(ProgramError.accountDiscriminatorMismatch());
	}
	if (bytes.length < size || !accountCodecFieldsValid<T>(bytes)) {
		return Result.err(ProgramError.accountDidNotDeserialize());
	}
	const value: T = accountCodecRead<T>(bytes);
	return Result.ok(value);
}

export function encode<T>(value: T): Result<uint8[], ProgramError> {
	if (!accountCodecValueValid<T>(value)) { return Result.err(ProgramError.accountDidNotDeserialize()); }
	const size: int32 = accountCodecSize<T>();
	const discriminator = @comptime { return word(T.discriminator()); };
	const bytes = accountByteArray(size);
	accountWriteUnsigned(bytes, 0, 8, discriminator);
	accountCodecWrite<T>(bytes, value);
	return Result.ok(bytes);
}
