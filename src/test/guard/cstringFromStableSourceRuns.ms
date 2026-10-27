// nim-guard: implicit string → cstring — stable sources keep converting.
//
// INVARIANT (implicit cstring conversion): a string literal and a const bound
//   to one outlive any cstring taken from them; as a call argument, a
//   temporary, a const, a parameter or local the function never assigns, and
//   a field, element or module variable the call keeps alive all live through
//   the call, also behind an `as` or `!` that only narrows; a local assigned
//   only outside nested functions and the call's own arguments lives through
//   the call too, whatever it was assigned before or after; a conditional is
//   stable when each branch is; `as cstring` stays the author's explicit
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

class Box { name: string = "box-name"; }
const box = new Box();
const names: string[] = ["element"];
let current: string = "current";

function renameThenMeasure(c: cstring): int64 {
	box.name = "other";
	return strlen(c);
}

function resetThenMeasure(c: cstring): int64 {
	current = "reset";
	return strlen(c);
}

function pick(flag: boolean): string | null {
	return flag ? "picked" : null;
}

function fromNarrowedConstCast(): int64 {
	const mapped = pick(true);
	return strlen(mapped as string) + strlen(mapped!);
}

function fromParameterCast(p: string | null): int64 {
	return strlen(p as string);
}

function explicitConversion(n: int32): int64 {
	const s: string = "value-" + n.toString();
	return strlen(s as cstring);
}

function conditionalConst(p: string): int64 {
	const v = p;
	return strlen(v === "" ? "auto" : v);
}

function nestedConditional(p: string): int64 {
	const v = p;
	return strlen(p === "" ? "auto" : (p === "x" ? "ex" : v));
}

function assignedBeforeCall(parts: string[]): int64 {
	let text = "";
	for (const part of parts) { text += part; }
	return strlen(text);
}

function reassignedInLoopBeforeEachCall(n: int32): int64 {
	let text = "";
	let total: int64 = 0;
	for (let i = 0; i < n; i += 1) {
		text = text + "ab";
		total += strlen(text);
	}
	return total;
}

function assignedAfterCallInLoop(n: int32): int64 {
	let text = "ab";
	let total: int64 = 0;
	for (let i = 0; i < n; i += 1) {
		total += strlen(text);
		text = text + "ab";
	}
	return total;
}

function assignedLocalBehindCast(n: int32): int64 {
	let shifted: string | null = "value-" + n.toString();
	shifted = "other";
	return strlen(shifted as string);
}

const literalLocal: cstring = "abc";
if (strlen(literalLocal) != 3) { throw "GUARD RED: literal local"; }
if (strlen("abcd") != 4) { throw "GUARD RED: literal argument"; }
if (strlen(GREETING) != 5) { throw "GUARD RED: const argument"; }
if (fromParameter("abcdef") != 12) { throw "GUARD RED: parameter"; }
if (fromNarrowedConstCast() != 12) { throw "GUARD RED: cast of a narrowed const argument"; }
if (fromParameterCast("abc") != 3) { throw "GUARD RED: cast of a parameter argument"; }
if (explicitConversion(7) != 7) { throw "GUARD RED: explicit conversion"; }
if (fromLocalArgument(3) != 7) { throw "GUARD RED: local argument"; }
if (fromTemporaryArgument(4) != 7) { throw "GUARD RED: temporary argument"; }
if (strlen(made(5)) != 6) { throw "GUARD RED: call result argument"; }
if (renameThenMeasure(box.name) != 8) { throw "GUARD RED: field into author code"; }
if (resetThenMeasure(current) != 7) { throw "GUARD RED: module variable into author code"; }
if (strlen(names[0]) != 7) { throw "GUARD RED: element into an extern function"; }
for (const name of [`top-${3}`, "level"]) {
	if (strlen(name) != 5) { throw "GUARD RED: top-level loop const argument"; }
}
if (conditionalConst("") != 4 || conditionalConst("abcde") != 5) { throw "GUARD RED: conditional of a literal and a const"; }
if (nestedConditional("") != 4 || nestedConditional("x") != 2 || nestedConditional("abc") != 3) { throw "GUARD RED: nested conditional"; }
if (assignedBeforeCall(["ab", "cde"]) != 5) { throw "GUARD RED: local assigned before the call"; }
if (reassignedInLoopBeforeEachCall(3) != 12) { throw "GUARD RED: local reassigned in a loop before the call"; }
if (assignedAfterCallInLoop(3) != 12) { throw "GUARD RED: local assigned after the call in a loop"; }
if (assignedLocalBehindCast(1) != 5) { throw "GUARD RED: assigned local behind a cast"; }
console.log("GUARD-OK");
