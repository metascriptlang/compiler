// GUARD — the append door must be chosen by BYTES, not by UTF-16 length.
//
// There are two in-place append primitives: msStringAppend(&s, src) takes a
// whole string, msStringAppendChar(&s, c) takes one BYTE. stringOpLower routes
// a self-append to the char door only when the RHS literal is one UTF-16 unit
// AND under 128 — i.e. exactly one byte. The reference engine has the same two
// primitives but picks between them by ARGUMENT TYPE (a char literal vs a string
// literal); MS has no char literal to type-dispatch on, so the choice is made
// from the literal's SHAPE instead. That shape test is the whole safety
// argument, and it is one condition away from silent corruption.
//
// Drop the `< 128` half and `s + "é"` lowers to msStringAppendChar(&s, 233):
// one byte 0xE9 lands where the two bytes 0xC3 0xA9 belong. Drop the
// one-unit half and `s + "yz"` appends only 'y'.
//
// Why .length cannot be the assertion: the walk counts non-continuation bytes,
// and a lone 0xE9 is not a continuation byte — so a truncated "é" reports
// length 1 exactly like a correct one. Only byteLength (and comparing against a
// separately built string) separates them. A guard written in the style of
// stringAsciiCacheStale.ms would pass while the bytes are wrong.
//
// id() keeps the destination out of reach of constant folding; the appended
// operand must stay a bare literal or the door being guarded is never taken.

function id(s: string): string { return s; }

function main(): number {
	let failures = 0;

	// The char door itself — a 1-byte literal, the case the rewrite exists for.
	let a = id("x");
	a = a + "y";
	if (a.byteLength() !== 2 || a !== id("xy")) {
		console.log("GUARD RED: ascii char door, bytes=" + a.byteLength() + " s=" + a);
		failures = failures + 1;
	}

	// One UTF-16 unit, TWO bytes — must stay on the string door.
	let b = id("a");
	b = b + "é";
	if (b.byteLength() !== 3 || b.length !== 2 || b !== id("aé")) {
		console.log("GUARD RED: 2-byte literal took the char door, bytes=" + b.byteLength() + " len=" + b.length + " s=" + b);
		failures = failures + 1;
	}

	// Same hazard through the `+=` lowering site.
	let c = id("a");
	c += "é";
	if (c.byteLength() !== 3 || c !== id("aé")) {
		console.log("GUARD RED: += 2-byte literal, bytes=" + c.byteLength() + " s=" + c);
		failures = failures + 1;
	}

	// Same hazard through the flattened-chain site (msStringConcatArr → AppendArr).
	let d = id("a");
	d = d + "é" + "z";
	if (d.byteLength() !== 4 || d.length !== 3 || d !== id("aéz")) {
		console.log("GUARD RED: chain 2-byte literal, bytes=" + d.byteLength() + " len=" + d.length + " s=" + d);
		failures = failures + 1;
	}

	// Three-byte literal, still one UTF-16 unit.
	let e = id("a");
	e = e + "€";
	if (e.byteLength() !== 4 || e.length !== 2 || e !== id("a€")) {
		console.log("GUARD RED: 3-byte literal took the char door, bytes=" + e.byteLength() + " len=" + e.length + " s=" + e);
		failures = failures + 1;
	}

	// Multi-character literal — the other half of the shape test.
	let f = id("a");
	f = f + "yz";
	if (f.byteLength() !== 3 || f !== id("ayz")) {
		console.log("GUARD RED: multi-char literal truncated, bytes=" + f.byteLength() + " s=" + f);
		failures = failures + 1;
	}

	// An escape is one unit and one byte, so it SHOULD take the char door —
	// and must arrive as the control character, not as a backslash pair.
	let g = id("a");
	g = g + "\n";
	if (g.byteLength() !== 2 || g.charCodeAt(1) !== 10) {
		console.log("GUARD RED: escape literal, bytes=" + g.byteLength() + " code=" + g.charCodeAt(1));
		failures = failures + 1;
	}

	// Repeated char-door appends must keep the ASCII answer composable: the
	// flag protocol is what the door split has to preserve.
	let h = id("");
	let i = 0;
	while (i < 40) { h = h + "q"; i = i + 1; }
	if (h.byteLength() !== 40 || h.length !== 40) {
		console.log("GUARD RED: repeated char door, bytes=" + h.byteLength() + " len=" + h.length);
		failures = failures + 1;
	}
	h = h + "é";
	if (h.byteLength() !== 42 || h.length !== 41) {
		console.log("GUARD RED: non-ascii after char-door run, bytes=" + h.byteLength() + " len=" + h.length);
		failures = failures + 1;
	}

	if (failures === 0) console.log("GUARD-OK stringAppendCharDoor");
	return failures;
}

const guardRc = main();
if (guardRc !== 0) process.exit(guardRc);
