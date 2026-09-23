// Symptom: `try` accepted a callee error type the enclosing function could not return, with no converter declared, and no diagnostic was given.
// Root cause: checkTryExpr never compared the propagated error type with the enclosing function's.
// Fix: without an assignable error type or a converter for the pair, the `try` is a type error naming both types; two converters for the pair stay the existing ambiguity error.
import { compileToCWithStd } from "../helpers";

function tryError209(extra: string, body: string): string {
	const result = compileToCWithStd(`
enum AccountError { MissingSigner, WrongOwner }
enum PetError { Account, Dead }
${extra}
function load(): Result<uint64, AccountError> { return Result.err(AccountError.WrongOwner); }
function feed(): Result<uint64, PetError> {
	${body}
}
async function feedLater(): Promise<Result<uint64, PetError>> {
	${body}
}
function main(): int32 { feed(); return 0; }
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug209: try without a converter for the error pair is a type error" {
	const error = tryError209("", "const v = try load(); return Result.ok(v);");
	assert error.indexOf("'try' propagates error type 'AccountError' but 'feed' returns error type 'PetError'", 0) >= 0, error;
	assert error.indexOf("'try' propagates error type 'AccountError' but 'feedLater' returns error type 'PetError'", 0) >= 0, error;
}

test "bug209: try as a returned expression without a converter is a type error" {
	const error = tryError209("", "return Result.ok(try load());");
	assert error.indexOf("'try' propagates error type 'AccountError' but 'feed' returns error type 'PetError'", 0) >= 0, error;
}

test "bug209: two converters for the error pair are ambiguous, not silently chosen" {
	const error = tryError209(`
converter toPetA(e: AccountError): PetError { return PetError.Account; }
converter toPetB(e: AccountError): PetError { return PetError.Dead; }
`, "const v = try load(); return Result.ok(v);");
	assert error.indexOf("'toPetA' and 'toPetB' both convert 'AccountError' to 'PetError'", 0) >= 0, error;
	assert error.indexOf("'try' propagates error type", 0) < 0, error;
}

test "bug209: try with a declared converter compiles" {
	const error = tryError209("converter toPet(e: AccountError): PetError { return PetError.Account; }", "const v = try load(); return Result.ok(v);");
	assert error == "", error;
}
