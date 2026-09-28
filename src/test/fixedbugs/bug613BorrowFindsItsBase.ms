// Symptom: `@borrow function key(this s: Signer): Pubkey;` was "Decorators are not valid here", and a body-less `this` function on a distinct never became a method, so a distinct type could reach its base's functions and fields only through a hand-written body per function.
// Root cause: the language had no borrow; the parser also joined the overload flag with a space, so a body-less function's receiver read as "Signer overload".
// Fix: `@borrow` on a body-less function resolves, once at its declaration, the function of the same name that takes the distinct's base, and every call is exchanged for that base before any later pass; `@borrow` on a distinct type lets field access read through to the base.
import { compileToCWithStd } from "../helpers";

function error613(body: string): string {
	const result = compileToCWithStd(`
struct Account613 { address: uint64; lamports: uint64; }
function key(this a: Account613): uint64 { return a.address * 2; }
type Signer613 = distinct Account613;
${body}
`);
	return result.ok ? "" : result.error;
}

test "bug613: a borrowed function and a borrowed dot compile" {
	const error = error613(`
@borrow function key(this s: Signer613): uint64;
@borrow type Payer613 = distinct Account613;
const a: Account613 = { address: 21, lamports: 5 };
const k: uint64 = (a as Signer613).key() + key(a as Signer613);
const l: uint64 = (a as Payer613).lamports;
`);
	assert error == "", error;
}

test "bug613: without @borrow a distinct has neither its base's methods nor its fields" {
	const method = error613("const a: Account613 = { address: 21, lamports: 5 }; const k = (a as Signer613).key();");
	assert method.indexOf("Property 'key' does not exist on type 'Signer613'", 0) >= 0, method;
	const field = error613("const a: Account613 = { address: 21, lamports: 5 }; const l = (a as Signer613).lamports;");
	assert field.indexOf("Property 'lamports' does not exist on type 'Signer613'", 0) >= 0, field;
}

test "bug613: a borrow needs a distinct parameter, a base of the same name and the same return type" {
	const noDistinct = error613("@borrow function key(this a: Account613): uint64;");
	assert noDistinct.indexOf("@borrow 'key' has no distinct parameter", 0) >= 0, noDistinct;
	const noBase = error613("@borrow function tag(this s: Signer613): uint64;");
	assert noBase.indexOf("@borrow 'tag': no tag(Account613) to borrow from", 0) >= 0, noBase;
	const otherReturn = error613("@borrow function key(this s: Signer613): int32;");
	assert otherReturn.indexOf("@borrow 'key' returns 'int32' but key(Account613) returns 'uint64'", 0) >= 0, otherReturn;
}

test "bug613: a borrow has no body, takes no arguments and applies to a function or a distinct type" {
	const body = error613("@borrow function key(this s: Signer613): uint64 { return 1; }");
	assert body.indexOf("@borrow takes the body of the base function", 0) >= 0, body;
	const args = error613("@borrow(x) function key(this s: Signer613): uint64;");
	assert args.indexOf("@borrow takes no arguments", 0) >= 0, args;
	const plainAlias = error613("@borrow type Plain613 = Account613;");
	assert plainAlias.indexOf("only a distinct type can borrow its base's fields", 0) >= 0, plainAlias;
	const constant = error613("@borrow const k613 = 1;");
	assert constant.indexOf("@borrow applies to a function or a distinct type", 0) >= 0, constant;
}

test "bug613: a borrow does not reach a generic base" {
	const error = error613(`
type Heap613<T> = distinct T[];
function size613<T>(a: T[]): int32 { return a.length as int32; }
@borrow function size613<T>(h: Heap613<T>): int32;
`);
	assert error.indexOf("@borrow 'size613' cannot borrow from a generic function", 0) >= 0, error;
}
