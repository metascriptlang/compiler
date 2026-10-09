export struct ProgramError {
	code: uint64;
}

function builtinError(index: uint64): ProgramError {
	return { code: index << 32 };
}

export function custom(this typeof ProgramError, code: uint32): ProgramError {
	if (code == 0) { return builtinError(1); }
	return { code: code as uint64 };
}

export function userError(this typeof ProgramError, ordinal: uint32): ProgramError {
	return ProgramError.custom(6000 + ordinal);
}

export function isCustom(this error: ProgramError): boolean {
	return error.code != 0 && error.code < 0x100000000;
}

export function customCode(this error: ProgramError): uint32 {
	return error.isCustom() ? error.code as uint32 : 0;
}

export function invalidArgument(this typeof ProgramError): ProgramError { return builtinError(2); }
export function invalidInstructionData(this typeof ProgramError): ProgramError {
	return builtinError(3);
}
export function invalidAccountData(this typeof ProgramError): ProgramError {
	return builtinError(4);
}
export function accountDataTooSmall(this typeof ProgramError): ProgramError {
	return builtinError(5);
}
export function insufficientFunds(this typeof ProgramError): ProgramError {
	return builtinError(6);
}
export function incorrectProgramId(this typeof ProgramError): ProgramError {
	return builtinError(7);
}
export function missingRequiredSignature(this typeof ProgramError): ProgramError {
	return builtinError(8);
}
export function accountAlreadyInitialized(this typeof ProgramError): ProgramError {
	return builtinError(9);
}
export function uninitializedAccount(this typeof ProgramError): ProgramError {
	return builtinError(10);
}
export function notEnoughAccountKeys(this typeof ProgramError): ProgramError {
	return builtinError(11);
}
export function accountBorrowFailed(this typeof ProgramError): ProgramError {
	return builtinError(12);
}
export function maxSeedLengthExceeded(this typeof ProgramError): ProgramError {
	return builtinError(13);
}
export function invalidSeeds(this typeof ProgramError): ProgramError { return builtinError(14); }
export function accountNotRentExempt(this typeof ProgramError): ProgramError {
	return builtinError(16);
}
export function illegalOwner(this typeof ProgramError): ProgramError { return builtinError(18); }
export function invalidRealloc(this typeof ProgramError): ProgramError { return builtinError(20); }
export function invalidAccountOwner(this typeof ProgramError): ProgramError {
	return builtinError(23);
}
export function arithmeticOverflow(this typeof ProgramError): ProgramError {
	return builtinError(24);
}
export function immutable(this typeof ProgramError): ProgramError { return builtinError(25); }
export function incorrectAuthority(this typeof ProgramError): ProgramError {
	return builtinError(26);
}

export function instructionMissing(this typeof ProgramError): ProgramError {
	return ProgramError.custom(100);
}
export function instructionFallbackNotFound(this typeof ProgramError): ProgramError {
	return ProgramError.custom(101);
}
export function instructionDidNotDeserialize(this typeof ProgramError): ProgramError {
	return ProgramError.custom(102);
}
export function constraintMut(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2000);
}
export function constraintHasOne(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2001);
}
export function constraintSigner(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2002);
}
export function constraintRaw(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2003);
}
export function constraintOwner(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2004);
}
export function constraintRentExempt(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2005);
}
export function constraintSeeds(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2006);
}
export function constraintExecutable(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2007);
}
export function constraintAssociated(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2009);
}
export function constraintAssociatedInit(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2010);
}
export function constraintClose(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2011);
}
export function constraintAddress(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2012);
}
export function constraintZero(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2013);
}
export function constraintTokenMint(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2014);
}
export function constraintTokenOwner(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2015);
}
export function constraintMintDecimals(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2018);
}
export function constraintSpace(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2019);
}
export function constraintTokenTokenProgram(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2021);
}
export function constraintMintTokenProgram(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2022);
}
export function constraintAssociatedTokenTokenProgram(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2023);
}
export function requireViolated(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2500);
}
export function requireKeysEqViolated(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2502);
}
export function requireKeysNeqViolated(this typeof ProgramError): ProgramError {
	return ProgramError.custom(2504);
}
export function accountDiscriminatorAlreadySet(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3000);
}
export function accountDiscriminatorNotFound(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3001);
}
export function accountDiscriminatorMismatch(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3002);
}
export function accountDidNotDeserialize(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3003);
}
export function accountNotEnoughKeys(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3005);
}
export function accountNotMutable(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3006);
}
export function accountOwnedByWrongProgram(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3007);
}
export function invalidProgramId(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3008);
}
export function invalidProgramExecutable(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3009);
}
export function accountNotSigner(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3010);
}
export function accountNotSystemOwned(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3011);
}
export function accountNotInitialized(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3012);
}
export function accountNotAssociatedTokenAccount(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3014);
}
export function accountSysvarMismatch(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3015);
}
export function accountReallocExceedsLimit(this typeof ProgramError): ProgramError {
	return ProgramError.custom(3016);
}
export function tryingToInitPayerAsProgramAccount(this typeof ProgramError): ProgramError {
	return ProgramError.custom(4101);
}
export function invalidNumericConversion(this typeof ProgramError): ProgramError {
	return ProgramError.custom(4102);
}

enum SampleError {
	Shielded,
	EmptyHarvest,
}

converter sampleError(error: SampleError): ProgramError {
	return ProgramError.userError(error as uint32);
}

function failsWithSample(): Result<uint64, SampleError> {
	return Result.err(SampleError.EmptyHarvest);
}

function handler(): Result<uint64, ProgramError> {
	const value = try failsWithSample();
	return Result.ok(value);
}

test "builtin errors sit in the high word and custom zero is not success" {
	assert ProgramError.custom(0).code == 0x100000000;
	assert ProgramError.missingRequiredSignature().code == 0x800000000;
	assert ProgramError.accountBorrowFailed().code == 0xC00000000;
	assert !ProgramError.invalidArgument().isCustom();
}

test "framework and user errors carry Anchor's codes" {
	assert ProgramError.constraintSeeds().customCode() == 2006;
	assert ProgramError.accountDiscriminatorMismatch().customCode() == 3002;
	assert ProgramError.userError(0).customCode() == 6000;
}

test "try converts a domain error through its converter" {
	const result = handler();
	assert !result.ok;
	if (!result.ok) { assert result.error.customCode() == 6001; }
}
