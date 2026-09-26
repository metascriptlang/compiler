// Symptom: `try` accepted a callee error type the enclosing function could not return, with no converter declared, and no diagnostic was given.
// Root cause: checkTryExpr never compared the propagated error type with the enclosing function's.
// Fix: without an assignable error type or a converter for the pair, the `try` is a type error naming both types, also once an inferred return settles and per generic instance; two converters for the pair stay the existing ambiguity error; a `try` without `catch` where no Result can be returned is a named error.
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

function tryProgram209(program: string): string {
	const result = compileToCWithStd(`
enum AccountError { MissingSigner, WrongOwner }
enum PetError { Account, Dead }
function load(): Result<uint64, AccountError> { return Result.err(AccountError.WrongOwner); }
${program}
`);
	return result.ok ? "" : result.error;
}

test "bug209: a mismatch is reported once an inferred return settles" {
	const error = tryProgram209(`
function feed(fail: boolean) {
	if (fail) return Result.err(PetError.Dead) as Result<uint64, PetError>;
	const v = try load();
	return Result.ok(v) as Result<uint64, PetError>;
}
const arrow = () => { const v = try load(); return Result.ok(v) as Result<uint64, PetError>; };
feed(false); arrow();
`);
	assert error.indexOf("'try' propagates error type 'AccountError' but 'feed' returns error type 'PetError'", 0) >= 0, error;
	assert error.indexOf("'try' propagates error type 'AccountError' but '<arrow>' returns error type 'PetError'", 0) >= 0, error;
}

test "bug209: a mismatch is reported for the generic instance that has it" {
	const error = tryProgram209(`
function feed<E>(fallback: E): Result<uint64, E> { const v = try load(); return Result.ok(v); }
feed<AccountError>(AccountError.MissingSigner);
feed<PetError>(PetError.Dead);
`);
	assert error.indexOf("'try' propagates error type 'AccountError' but 'feed", 0) >= 0, error;
	assert error.indexOf("returns error type 'PetError'", 0) >= 0, error;
	assert error.indexOf("returns error type 'AccountError'", 0) < 0, error;
}

test "bug209: try without catch where no Result can be returned is a named error" {
	const annotated = tryProgram209(`function plain(): int32 { const v = try load(); return v as int32; } plain();`);
	assert annotated.indexOf("'try' without 'catch' returns its error, but 'plain' returns 'int32', not a Result", 0) >= 0, annotated;
	const inferredVoid = tryProgram209(`function run() { const v = try load(); console.log(v); } run();`);
	assert inferredVoid.indexOf("'try' without 'catch' returns its error, but 'run' returns 'void', not a Result", 0) >= 0, inferredVoid;
	const arrowVoid = tryProgram209(`const f = () => { const v = try load(); console.log(v); }; f();`);
	assert arrowVoid.indexOf("'try' without 'catch' returns its error, but '<arrow>' returns 'void', not a Result", 0) >= 0, arrowVoid;
	const topLevel = tryProgram209(`const v = try load(); console.log(v);`);
	assert topLevel.indexOf("'try' without 'catch' returns its error, but module top-level code cannot return", 0) >= 0, topLevel;
}

test "bug209: try with catch stays valid where no Result can be returned" {
	const error = tryProgram209(`function plain(): int32 { const v = try load() catch 0; return v as int32; } const top = try load() catch 1; plain();`);
	assert error == "", error;
}
