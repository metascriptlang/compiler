// nim-guard: a string literal payload is never written
//
// INVARIANT (the reference engine's strs_v2 isLiteral COW rule, ported as
//   msIsLiteral): every in-place engine op copies a literal payload before it
//   writes a single byte. Codegen emits literals as `static const` (.rodata)
//   with the ASCII answer baked in, so a write is not merely wrong — it is a
//   fault. The language surface stays immutable regardless; that half is
//   pinned by stringImmutableSurface.ms, which deliberately excludes the
//   ENGINE tier (msStringSetChar/SetLength/SetSlice). This guard pins the tier
//   the sibling leaves out.
//
// WHAT IT CATCHES: an in-place op that writes a terminator or memmoves without
//   routing through msStringPrepareMutation. msStringSetSlice had exactly two
//   such paths — the tail trim (start == 0) and the empty result — and both are
//   reachable from ordinary user code through stripInPlace()/setSlice().
//
// RED MEANS: SIGBUS on a const payload, or — on a runtime that still emits
//   writable literals — a NUL punched into the middle of the SHARED literal
//   that every other user of that spelling sees. Proven red 2026-08-15: exit
//   138 under the const-literal runtime, and byteAt(2) == 0 instead of 32
//   under the installed one, which reported no error at all.

function id(s: string): string { return s; }

function main(): number {
	let failures = 0;

	// Tail trim writes the terminator at the new end.
	let tail = id("hi  ");
	tail.stripInPlace();
	if (tail != "hi" || tail.length != 2) {
		console.log("GUARD RED: tail trim=[" + tail + "] len=" + tail.length + " expected [hi] 2");
		failures = failures + 1;
	}

	// The pool interns by spelling, so a scribble into the literal shows up here.
	const sharedTail = id("hi  ");
	if (sharedTail.length != 4 || sharedTail.byteAt(2) != 32) {
		console.log("GUARD RED: shared literal len=" + sharedTail.length + " byteAt(2)=" + sharedTail.byteAt(2) + " expected 4 32");
		failures = failures + 1;
	}

	// Empty result writes the terminator at offset 0.
	let blank = id("   ");
	blank.stripInPlace();
	if (blank.length != 0) {
		console.log("GUARD RED: emptied literal len=" + blank.length + " expected 0");
		failures = failures + 1;
	}
	const sharedBlank = id("   ");
	if (sharedBlank.length != 3 || sharedBlank.byteAt(0) != 32) {
		console.log("GUARD RED: shared blank len=" + sharedBlank.length + " byteAt(0)=" + sharedBlank.byteAt(0) + " expected 3 32");
		failures = failures + 1;
	}

	// Leading trim always copied (start > 0) — the neighbour that bounds the bug.
	let lead = id("  hi");
	lead.stripInPlace();
	const sharedLead = id("  hi");
	if (lead != "hi" || sharedLead.length != 4 || sharedLead.byteAt(0) != 32) {
		console.log("GUARD RED: leading trim=[" + lead + "] shared len=" + sharedLead.length + " byteAt(0)=" + sharedLead.byteAt(0));
		failures = failures + 1;
	}

	// setSlice is the same engine op one call lower down.
	let cut = id("abcdef");
	cut.setSlice(0, 3);
	const sharedCut = id("abcdef");
	if (cut != "abc" || sharedCut.length != 6 || sharedCut.byteAt(3) != 100) {
		console.log("GUARD RED: setSlice=[" + cut + "] shared len=" + sharedCut.length + " byteAt(3)=" + sharedCut.byteAt(3));
		failures = failures + 1;
	}

	if (failures == 0) console.log("GUARD-OK stringLiteralNeverWritten");
	return failures;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
