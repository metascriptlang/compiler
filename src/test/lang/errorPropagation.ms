function testRaiseMayRaise(x: int32): int32 {
    if (x < 0) { throw "neg"; }
    return x + 1;
}

const statementTryTrail: string[] = [];

function statementTryStep(name: string, ok: boolean): Result<void, string> {
	statementTryTrail.push(name);
	return ok ? Result.ok(null) : Result.err(name + " failed");
}

function statementTryBoth(first: boolean, second: boolean): Result<void, string> {
	try statementTryStep("first", first);
	try statementTryStep("second", second);
	return Result.ok(null);
}

function statementTryGuarded(ok: boolean): Result<string, string> {
	if (ok) try statementTryStep("guard", true);
	else try statementTryStep("guard", false);
	return Result.ok("after");
}

enum ErrorConversionAccountError { MissingSigner, WrongOwner }

enum ErrorConversionPetError { Account, Dead }

enum ErrorConversionFightError { Pet, Timeout }

type ErrorConversionProgramError = distinct uint64;

converter errorConversionAccountToPet(e: ErrorConversionAccountError): ErrorConversionPetError {
	return e == ErrorConversionAccountError.WrongOwner ? ErrorConversionPetError.Account : ErrorConversionPetError.Dead;
}

converter errorConversionAccountToProgram(e: ErrorConversionAccountError): ErrorConversionProgramError {
	return (1000 + (e as int32)) as uint64 as ErrorConversionProgramError;
}

converter errorConversionPetToFight(e: ErrorConversionPetError): ErrorConversionFightError {
	return e == ErrorConversionPetError.Account ? ErrorConversionFightError.Pet : ErrorConversionFightError.Timeout;
}

function errorConversionLoad(fail: boolean): Result<uint64, ErrorConversionAccountError> {
	if (fail) return Result.err(ErrorConversionAccountError.WrongOwner);
	return Result.ok(7);
}

function errorConversionReload(fail: boolean): Result<uint64, ErrorConversionAccountError> {
	const value = try errorConversionLoad(fail);
	return Result.ok(value + 1);
}

function errorConversionFeed(fail: boolean): Result<uint64, ErrorConversionPetError> {
	const value = try errorConversionLoad(fail);
	return Result.ok(value * 2);
}

function errorConversionCharge(fail: boolean): Result<uint64, ErrorConversionProgramError> {
	const value = try errorConversionLoad(fail);
	return Result.ok(value * 3);
}

function errorConversionFight(fail: boolean): Result<uint64, ErrorConversionFightError> {
	const value = try errorConversionFeed(fail);
	return Result.ok(value + 100);
}

async function errorConversionLoadLater(fail: boolean): Promise<Result<uint64, ErrorConversionAccountError>> {
	return errorConversionLoad(fail);
}

async function errorConversionFeedLater(fail: boolean): Promise<Result<uint64, ErrorConversionPetError>> {
	const value = try (await errorConversionLoadLater(fail));
	return Result.ok(value + 5);
}

function errorConversionFeedInferred(fail: boolean) {
	const value = try errorConversionLoad(fail);
	return Result.ok(value) as Result<uint64, ErrorConversionPetError>;
}

function errorConversionFeedGeneric<E>(fail: boolean, fallback: E): Result<uint64, E> {
	const value = try errorConversionLoad(fail);
	return Result.ok(value);
}

struct AccountFault { code: int32; }

struct PetFault { code: int32; }

struct FightFault { code: int32; }

converter errorConversionAccountFaultToPet(e: AccountFault): PetFault {
	return { code: e.code + 100 };
}

converter errorConversionPetFaultToFight(e: PetFault): FightFault {
	return { code: e.code + 1000 };
}

function errorConversionLoadFault(fail: boolean): Result<int32, AccountFault> {
	if (fail) return Result.err({ code: 7 });
	return Result.ok(1);
}

function errorConversionReloadFault(fail: boolean): Result<int32, AccountFault> {
	const value = try errorConversionLoadFault(fail);
	return Result.ok(value + 1);
}

function errorConversionFeedFault(fail: boolean): Result<int32, PetFault> {
	const value = try errorConversionLoadFault(fail);
	return Result.ok(value + 1);
}

function errorConversionFightFault(fail: boolean): Result<int32, FightFault> {
	const value = try errorConversionFeedFault(fail);
	return Result.ok(value + 1);
}

test "errorPropagation: no-try raising call in a test block compiles and runs" {
    const a = testRaiseMayRaise(1);
    assert a == 2;
}

test "errorPropagation: a try statement continues after an ok void result" {
	statementTryTrail.length = 0;
	const r = statementTryBoth(true, true);
	assert r.ok;
	assert statementTryTrail.length == 2;
}

test "errorPropagation: a try statement returns the error and skips the rest" {
	statementTryTrail.length = 0;
	const r = statementTryBoth(false, true);
	assert !r.ok;
	if (!r.ok) assert r.error == "first failed";
	assert statementTryTrail.length == 1;
}

test "errorPropagation: a try statement as an unbraced if body propagates" {
	const good = statementTryGuarded(true);
	assert good.ok;
	if (good.ok) assert good.value == "after";
	const bad = statementTryGuarded(false);
	assert !bad.ok;
	if (!bad.ok) assert bad.error == "guard failed";
}

test "errorPropagation: try with the same error type passes the error through" {
	const ok = errorConversionReload(false);
	assert ok.ok && ok.value == 8;
	const err = errorConversionReload(true);
	assert !err.ok && err.error == ErrorConversionAccountError.WrongOwner;
}

test "errorPropagation: try converts an enum error through its converter" {
	const ok = errorConversionFeed(false);
	assert ok.ok && ok.value == 14;
	const err = errorConversionFeed(true);
	assert !err.ok && err.error == ErrorConversionPetError.Account;
}

test "errorPropagation: try converts between distinct struct errors of identical fields" {
	const ok = errorConversionFeedFault(false);
	assert ok.ok && ok.value == 2;
	const err = errorConversionFeedFault(true);
	assert !err.ok && err.error.code == 107;
}

test "errorPropagation: try with the same struct error type passes the error through" {
	const ok = errorConversionReloadFault(false);
	assert ok.ok && ok.value == 2;
	const err = errorConversionReloadFault(true);
	assert !err.ok && err.error.code == 7;
}

test "errorPropagation: the converter is chosen by the target error type" {
	const err = errorConversionCharge(true);
	assert !err.ok && (err.error as uint64) == 1001;
	const ok = errorConversionCharge(false);
	assert ok.ok && ok.value == 21;
}

test "errorPropagation: a converted try inside a function reached by another converted try" {
	const ok = errorConversionFight(false);
	assert ok.ok && ok.value == 114;
	const err = errorConversionFight(true);
	assert !err.ok && err.error == ErrorConversionFightError.Pet;
}

test "errorPropagation: a struct error crosses two converted try levels, one conversion each" {
	const ok = errorConversionFightFault(false);
	assert ok.ok && ok.value == 3;
	const err = errorConversionFightFault(true);
	assert !err.ok && err.error.code == 1107;
}

test "errorPropagation: an async try converts through its converter" {
	const ok = await errorConversionFeedLater(false);
	assert ok.ok && ok.value == 12;
	const err = await errorConversionFeedLater(true);
	assert !err.ok && err.error == ErrorConversionPetError.Account;
}

test "errorPropagation: a try in a function without a return annotation converts once the return is inferred" {
	const err = errorConversionFeedInferred(true);
	assert !err.ok && err.error == ErrorConversionPetError.Account;
	const ok = errorConversionFeedInferred(false);
	assert ok.ok && ok.value == 7;
	const arrow = (fail: boolean) => { const value = try errorConversionLoad(fail); return Result.ok(value) as Result<uint64, ErrorConversionPetError>; };
	const viaArrow = arrow(true);
	assert !viaArrow.ok && viaArrow.error == ErrorConversionPetError.Account;
}

test "errorPropagation: a try in a generic function converts per instance" {
	const err = errorConversionFeedGeneric<ErrorConversionPetError>(true, ErrorConversionPetError.Dead);
	assert !err.ok && err.error == ErrorConversionPetError.Account;
	const same = errorConversionFeedGeneric<ErrorConversionAccountError>(true, ErrorConversionAccountError.MissingSigner);
	assert !same.ok && same.error == ErrorConversionAccountError.WrongOwner;
}
