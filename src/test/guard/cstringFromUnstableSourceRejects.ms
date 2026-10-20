// nim-guard: implicit string → cstring — the address must not outlive its string.
//
// INVARIANT (implicit cstring conversion): a cstring keeps no string alive, so
//   the checker takes one implicitly only from a string literal, a const bound
//   to one, or, as a call argument, a parameter the function never assigns.
//
// WHAT IT CATCHES: a cstring taken from a local that is reassigned afterwards,
//   from a temporary, or from a parameter the body assigns; each read freed
//   memory under ASan before the check (3/3, also through a spawn capture).
//   A parameter lives only for its call, so returning it as a cstring dangles
//   in the caller.
//
// RED MEANS: one of the diagnostics stopped firing.
//
// GUARD-CHECK-FAIL cannot take a cstring from 's'
// GUARD-CHECK-FAIL cannot take a cstring from 'p'
// GUARD-CHECK-FAIL cannot take a cstring from 'arg'
// GUARD-CHECK-FAIL cannot take a cstring from 'kept'
// GUARD-CHECK-FAIL cannot take a cstring from 'returned'
// GUARD-CHECK-FAIL cannot take a cstring from this expression

@include("string.h")
extern function strlen(s: cstring): int64;

function fromReassignedLocal(n: int32): int64 {
	let s: string = "value-" + n.toString();
	const c: cstring = s;
	s = "other";
	return strlen(c);
}

function fromAssignedParameter(p: string): int64 {
	p = p + "-other";
	return strlen(p);
}

function fromLocalArgument(n: int32): int64 {
	const arg: string = "value-" + n.toString();
	return strlen(arg);
}

function fromParameterKeptInLocal(kept: string): int64 {
	const c: cstring = kept;
	return strlen(c);
}

function fromReturnedParameter(returned: string): cstring {
	return returned;
}

function fromTemporary(n: int32): int64 {
	const c: cstring = "value-" + n.toString();
	return strlen(c);
}

console.log(fromReassignedLocal(1) + fromAssignedParameter("x") + fromLocalArgument(2) + fromParameterKeptInLocal("y") + strlen(fromReturnedParameter("z" + "w")) + fromTemporary(3));
