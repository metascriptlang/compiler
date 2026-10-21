// nim-guard: implicit string → cstring — stable sources keep converting.
//
// INVARIANT (implicit cstring conversion): a string literal and a const bound
//   to one outlive any cstring taken from them; as a call argument, a
//   temporary, a const, and a parameter or local the function never assigns
//   all live through the call; `as cstring` stays the author's explicit
//   conversion.
//
// WHAT IT CATCHES: the check refusing a source that outlives its cstring,
//   which would break every FFI call that passes a string parameter through.
//
// RED MEANS: a shape below is refused (check error), or a length is wrong.

@include("string.h")
extern function strlen(s: cstring): int64;

const GREETING = "hello";

function fromParameter(p: string): int64 {
	return strlen(p) * 2;
}

function fromLocalArgument(n: int32): int64 {
	const arg: string = "value-" + n.toString();
	return strlen(arg);
}

function fromTemporaryArgument(n: int32): int64 {
	return strlen(`value-${n}`);
}

function made(n: int32): string {
	return "made-" + n.toString();
}

function explicitConversion(n: int32): int64 {
	const s: string = "value-" + n.toString();
	return strlen(s as cstring);
}

const literalLocal: cstring = "abc";
if (strlen(literalLocal) != 3) { throw "GUARD RED: literal local"; }
if (strlen("abcd") != 4) { throw "GUARD RED: literal argument"; }
if (strlen(GREETING) != 5) { throw "GUARD RED: const argument"; }
if (fromParameter("abcdef") != 12) { throw "GUARD RED: parameter"; }
if (explicitConversion(7) != 7) { throw "GUARD RED: explicit conversion"; }
if (fromLocalArgument(3) != 7) { throw "GUARD RED: local argument"; }
if (fromTemporaryArgument(4) != 7) { throw "GUARD RED: temporary argument"; }
if (strlen(made(5)) != 6) { throw "GUARD RED: call result argument"; }
console.log("GUARD-OK");
