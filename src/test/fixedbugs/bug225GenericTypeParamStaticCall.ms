// Symptom: `T.accountKind()` inside a generic failed with "Undefined variable 'T'" on C and JS.
// Root cause: a generic instance replaced `T` only inside type annotations; the parameter name itself was never bound, so `T` as the object of a call did not resolve.
// Fix: each instance checks its body in a scope that binds every type parameter name to its concrete type.
struct Pet225 { a: uint8; }
struct Block225 { b: uint8; }
enum Kind225 { Plain, Fancy }
class Box225 { n: int32 = 0; static tag(): int32 { return 5; } }

function accountKind(this typeof Pet225): uint8 { return 2; }
function accountKind(this typeof Block225): uint8 { return 1; }
function first(this typeof Kind225): Kind225 { return Kind225.Fancy; }

function kindOf225<T>(): uint8 { return T.accountKind(); }
function kindThrough225<U>(): uint8 { return kindOf225<U>(); }
function kindOfValue225<T>(x: T): uint8 { return T.accountKind(); }
function firstOf225<T>(): T { return T.first(); }
function tagOf225<T>(): int32 { return T.tag(); }

test "bug225: T.f() calls the static extension of each type argument" {
	assert kindOf225<Pet225>() == 2;
	assert kindOf225<Block225>() == 1;
}

test "bug225: a type parameter handed on to another generic" {
	assert kindThrough225<Block225>() == 1;
}

test "bug225: an inferred type parameter" {
	const p: Pet225 = { a: 1 };
	assert kindOfValue225(p) == 2;
}

test "bug225: an enum and a class as the type argument" {
	assert firstOf225<Kind225>() == Kind225.Fancy;
	assert tagOf225<Box225>() == 5;
}
