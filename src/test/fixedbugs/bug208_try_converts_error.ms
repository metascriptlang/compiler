// Symptom: `try load()` returning `Result<T, AccountError>` inside a function returning `Result<U, PetError>` compiled and returned AccountError's ordinal read as a PetError.
// Root cause: checkTryExpr never compared the propagated error type with the enclosing function's, and the desugared early return copied the error unconverted.
// Fix: `try` passes an assignable error through, converts a non-assignable one through the converter declared for the pair, and is a type error otherwise (STD-SOLANA §5; the converter lookup is Nim's userConvMatch).

enum AccountError208 { MissingSigner, WrongOwner }
enum PetError208 { Account, Dead }
enum FightError208 { Pet, Timeout }
type ProgramError208 = distinct uint64;

converter accountToPet208(e: AccountError208): PetError208 {
	return e == AccountError208.WrongOwner ? PetError208.Account : PetError208.Dead;
}

converter accountToProgram208(e: AccountError208): ProgramError208 {
	return (1000 + (e as int32)) as uint64 as ProgramError208;
}

converter petToFight208(e: PetError208): FightError208 {
	return e == PetError208.Account ? FightError208.Pet : FightError208.Timeout;
}

function load208(fail: boolean): Result<uint64, AccountError208> {
	if (fail) return Result.err(AccountError208.WrongOwner);
	return Result.ok(7);
}

function reload208(fail: boolean): Result<uint64, AccountError208> {
	const value = try load208(fail);
	return Result.ok(value + 1);
}

function feed208(fail: boolean): Result<uint64, PetError208> {
	const value = try load208(fail);
	return Result.ok(value * 2);
}

function charge208(fail: boolean): Result<uint64, ProgramError208> {
	const value = try load208(fail);
	return Result.ok(value * 3);
}

function fight208(fail: boolean): Result<uint64, FightError208> {
	const value = try feed208(fail);
	return Result.ok(value + 100);
}

async function loadLater208(fail: boolean): Promise<Result<uint64, AccountError208>> {
	return load208(fail);
}

async function feedLater208(fail: boolean): Promise<Result<uint64, PetError208>> {
	const value = try (await loadLater208(fail));
	return Result.ok(value + 5);
}

function feedInferred208(fail: boolean) {
	const value = try load208(fail);
	return Result.ok(value) as Result<uint64, PetError208>;
}

function feedGeneric208<E>(fail: boolean, fallback: E): Result<uint64, E> {
	const value = try load208(fail);
	return Result.ok(value);
}

test "bug208: try with the same error type passes the error through" {
	const ok = reload208(false);
	assert ok.ok && ok.value == 8;
	const err = reload208(true);
	assert !err.ok && err.error == AccountError208.WrongOwner;
}

test "bug208: try converts an enum error through its converter" {
	const ok = feed208(false);
	assert ok.ok && ok.value == 14;
	const err = feed208(true);
	assert !err.ok && err.error == PetError208.Account;
}

test "bug208: the converter is chosen by the target error type" {
	const err = charge208(true);
	assert !err.ok && (err.error as uint64) == 1001;
	const ok = charge208(false);
	assert ok.ok && ok.value == 21;
}

test "bug208: a converted try inside a function reached by another converted try" {
	const ok = fight208(false);
	assert ok.ok && ok.value == 114;
	const err = fight208(true);
	assert !err.ok && err.error == FightError208.Pet;
}

test "bug208: an async try converts through its converter" {
	const ok = await feedLater208(false);
	assert ok.ok && ok.value == 12;
	const err = await feedLater208(true);
	assert !err.ok && err.error == PetError208.Account;
}

test "bug208: a try in a function without a return annotation converts once the return is inferred" {
	const err = feedInferred208(true);
	assert !err.ok && err.error == PetError208.Account;
	const ok = feedInferred208(false);
	assert ok.ok && ok.value == 7;
	const arrow = (fail: boolean) => { const value = try load208(fail); return Result.ok(value) as Result<uint64, PetError208>; };
	const viaArrow = arrow(true);
	assert !viaArrow.ok && viaArrow.error == PetError208.Account;
}

test "bug208: a try in a generic function converts per instance" {
	const err = feedGeneric208<PetError208>(true, PetError208.Dead);
	assert !err.ok && err.error == PetError208.Account;
	const same = feedGeneric208<AccountError208>(true, AccountError208.MissingSigner);
	assert !same.ok && same.error == AccountError208.WrongOwner;
}
