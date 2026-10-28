// @stdout: a no b a a-c ok
// note: Result.ok("a") into a slot Result<"a" | "b", string> binds T to the literal union from the contextual return type, in a plain return, a const, a ternary arm and a match arm, and a plain generic call does the same; an argument with no literal union around it still binds string.

type Kind = "a" | "b" | "c";
enum E { X, Y }

function id<T>(x: T): T { return x; }

function plainOk(): Result<Kind, string> {
	return Result.ok("a");
}
function plainErr(): Result<Kind, string> {
	return Result.err("no");
}
function constOk(): Result<Kind, string> {
	const r: Result<Kind, string> = Result.ok("b");
	return r;
}
function tern(f: boolean): Result<Kind, string> {
	return f ? Result.ok("a") : Result.err("no");
}
function viaMatch(e: E): Result<Kind, string> {
	return match (e) {
		E.X => Result.ok("a"),
		E.Y => Result.ok("c"),
	};
}
function generic(): Kind {
	return id("a");
}
function plainText(): string {
	const r: Result<string, string> = plainString();
	return r.ok ? r.value : r.error;
}
function plainString(): Result<string, string> {
	return Result.ok("ok");
}

function show(r: Result<Kind, string>): string {
	return r.ok ? r.value : r.error;
}
console.log(show(plainOk()), show(plainErr()), show(constOk()), show(tern(true)), generic() + "-" + show(viaMatch(E.Y)), plainText());
