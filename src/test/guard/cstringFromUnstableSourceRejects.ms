// nim-guard: implicit string → cstring — the address must not outlive its string.
//
// INVARIANT (implicit cstring conversion): a cstring keeps no string alive, so
//   the checker takes one implicitly only from a string literal, a const bound
//   to one, or a call argument, which the call keeps alive unless it is a
//   parameter or local the function assigns.
//
// WHAT IT CATCHES: a cstring taken from a local that is reassigned afterwards,
//   from a temporary kept past its statement, or from a parameter or local the
//   body assigns; each read freed memory under ASan before the check (3/3,
//   also through a spawn capture). A parameter lives only for its call, so
//   returning it as a cstring dangles in the caller. A field, element or
//   module variable passed as an argument is kept alive by the call instead
//   (corpus cstringArgumentKeptAcrossEventLoop).
//
// RED MEANS: one of the diagnostics stopped firing.
//
// GUARD-CHECK-FAIL cannot take a cstring from 's'
// GUARD-CHECK-FAIL cannot take a cstring from 'captured'
// GUARD-CHECK-FAIL cannot take a cstring from 'p'
// GUARD-CHECK-FAIL cannot take a cstring from 'moved'
// GUARD-CHECK-FAIL cannot take a cstring from 'kept'
// GUARD-CHECK-FAIL cannot take a cstring from 'returned'
// GUARD-CHECK-FAIL cannot take a cstring from this expression

@include("string.h")
extern function strlen(s: cstring): int64;

function fromReassignedLocal(n: int32): int64 {
	let s: string = "value-" + n.toString();
	const c: cstring = s; // GUARD-REFUSED
	s = "other";
	return strlen(c);
}

function fromReassignedLocalCapturedBySpawn(n: int32): int64 {
	let captured: string = "value-" + n.toString();
	const c: cstring = captured; // GUARD-REFUSED
	const f = spawn(() => strlen(c));
	captured = "other";
	return await f;
}

function fromAssignedParameter(p: string): int64 {
	p = p + "-other";
	return strlen(p); // GUARD-REFUSED
}

function fromAssignedLocalArgument(n: int32): int64 {
	let moved: string = "value-" + n.toString();
	moved = moved + "-other";
	return strlen(moved); // GUARD-REFUSED
}

function fromParameterKeptInLocal(kept: string): int64 {
	const c: cstring = kept; // GUARD-REFUSED
	return strlen(c);
}

function fromReturnedParameter(returned: string): cstring {
	return returned; // GUARD-REFUSED
}

function fromTemporary(n: int32): int64 {
	const c: cstring = "value-" + n.toString(); // GUARD-REFUSED
	return strlen(c);
}

console.log(fromReassignedLocal(1) + fromReassignedLocalCapturedBySpawn(4) + fromAssignedParameter("x") + fromAssignedLocalArgument(2) + fromParameterKeptInLocal("y") + strlen(fromReturnedParameter("z" + "w")) + fromTemporary(3));
