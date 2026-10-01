// Symptom: `try load()` with error type `AccountFault611 { code }` inside a function returning `PetFault611 { code }` skipped the declared converter: C failed at clang, JS returned the unconverted error (7, not 107).
// Root cause: the checker held two declared structs of the same fields assignable, so `try` found the pair assignable and never looked for a converter.
// Fix: a declared value struct accepts only its own type (bug610), so the pair is not assignable and `try` converts through the converter, as for any other error pair.

struct AccountFault611 { code: int32; }
struct PetFault611 { code: int32; }
struct FightFault611 { code: int32; }

converter accountToPet611(e: AccountFault611): PetFault611 {
	return { code: e.code + 100 };
}

converter petToFight611(e: PetFault611): FightFault611 {
	return { code: e.code + 1000 };
}

function load611(fail: boolean): Result<int32, AccountFault611> {
	if (fail) return Result.err({ code: 7 });
	return Result.ok(1);
}

function reload611(fail: boolean): Result<int32, AccountFault611> {
	const value = try load611(fail);
	return Result.ok(value + 1);
}

function feed611(fail: boolean): Result<int32, PetFault611> {
	const value = try load611(fail);
	return Result.ok(value + 1);
}

function fight611(fail: boolean): Result<int32, FightFault611> {
	const value = try feed611(fail);
	return Result.ok(value + 1);
}

test "bug611: try converts a same-shaped struct error through its converter" {
	const err = feed611(true);
	assert !err.ok && err.error.code == 107;
	const ok = feed611(false);
	assert ok.ok && ok.value == 2;
}

test "bug611: a converted try inside a function reached by another converted try" {
	const err = fight611(true);
	assert !err.ok && err.error.code == 1107;
}

test "bug611: the same struct error passes through unconverted" {
	const err = reload611(true);
	assert !err.ok && err.error.code == 7;
}
