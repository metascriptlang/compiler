// nim-guard: a string literal payload is never written
//
// INVARIANT (the reference engine's strs_v2 isLiteral rule, ported as
//   msIsLiteral): the only writers left on a string are the builders, and a
//   builder that meets a literal payload grows into a fresh buffer instead of
//   writing into it. Codegen emits literals as `static const` (.rodata) with
//   the ASCII answer baked in, so a write is not merely wrong, it is a fault.
//   The surface itself stays immutable (stringImmutableSurface.ms).
//
// WHAT IT CATCHES: `+=` growth (msStringAppend, AppendChar, AppendArr via
//   msStringPrepareAdd) writing the terminator or a byte into the literal's payload.
//
// RED MEANS: SIGBUS on a const payload, or a NUL or byte punched into the SHARED
//   literal that every other user of that spelling sees.

function id(s: string): string { return s; }

function main(): int32 {
	let failures = 0;

	let tail = id("hi  ");
	tail += "x";
	const sharedTail = id("hi  ");
	if (tail != "hi  x" || sharedTail.length != 4 || sharedTail.byteAt(2) != 32 || sharedTail.byteAt(3) != 32) {
		console.log("GUARD RED: grown literal=[" + tail + "] shared len=" + sharedTail.length + " byteAt(3)=" + sharedTail.byteAt(3));
		failures = failures + 1;
	}

	let single = id("abc");
	single += "!";
	const sharedSingle = id("abc");
	if (single != "abc!" || sharedSingle.length != 3 || sharedSingle.byteAt(0) != 97) {
		console.log("GUARD RED: single-char growth=[" + single + "] shared len=" + sharedSingle.length);
		failures = failures + 1;
	}

	let empty = id("");
	empty += "ab";
	if (empty != "ab" || id("").length != 0) {
		console.log("GUARD RED: grown empty=[" + empty + "] shared empty len=" + id("").length);
		failures = failures + 1;
	}

	const mid = id("-");
	let several = id("abcdef");
	several = several + mid + mid;
	const sharedSeveral = id("abcdef");
	if (several != "abcdef--" || sharedSeveral.length != 6 || sharedSeveral.byteAt(3) != 100) {
		console.log("GUARD RED: multi-part growth=[" + several + "] shared len=" + sharedSeveral.length + " byteAt(3)=" + sharedSeveral.byteAt(3));
		failures = failures + 1;
	}

	if (failures == 0) console.log("GUARD-OK stringLiteralNeverWritten");
	return failures;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
