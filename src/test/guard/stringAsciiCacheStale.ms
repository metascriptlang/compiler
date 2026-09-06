// GUARD — the cached is-ASCII answer must never outlive the bytes it describes.
//
// `.length` is UTF-16 code units over a UTF-8 payload (LANG.md §0), funded by
// MS_ASCII_CHECKED/MS_ASCII_FLAG in the payload `cap`. Those bits are an MS
// invention: the reference engine's `len` IS the byte count so it needs no such
// cache, and the JS engines fix the representation at CONSTRUCTION instead of
// recomputing on read. The hazard MS took on with them is staleness, in exactly
// one direction: a bit that still says "ASCII" after non-ASCII bytes arrive
// makes `.length` return the BYTE count. The opposite staleness is harmless —
// it only forces a rescan that computes the right answer anyway.
//
// The window is an append that FITS IN SPARE CAPACITY: msStringPrepareAdd only
// reallocs when it must, and a realloc is what used to clear the bits. So the
// probe must grow a string until it has slack, cache the flag by reading
// .length, then append a multi-byte character small enough not to force a
// realloc. `id()` keeps the operands out of reach of constant folding.
//
// Red on the pre-fix runtime: "abcd" + "é" reported length 6 (bytes), not 5.

function id(s: string): string { return s; }

function main(): number {
	let failures = 0;

	let s = id("ab");
	s = s + id("c");
	s = s + id("d");
	if (s.length != 4) {
		console.log("GUARD RED: ascii length=" + s.length + " expected 4");
		failures = failures + 1;
	}
	s = s + id("é");
	if (s.length != 5) {
		console.log("GUARD RED: stale ascii cache, length=" + s.length + " expected 5");
		failures = failures + 1;
	}

	// Control: the same content built without ever caching an ASCII answer.
	const fresh = id("abcdé");
	if (fresh.length != 5) {
		console.log("GUARD RED: fresh non-ascii length=" + fresh.length + " expected 5");
		failures = failures + 1;
	}

	// Control: an append that DOES force a realloc was always correct.
	let u = id("abcd");
	u = u + id("ef");
	u = u + id("ü");
	if (u.length != 7) {
		console.log("GUARD RED: realloc-path length=" + u.length + " expected 7");
		failures = failures + 1;
	}

	// The ASCII fast path must survive the fix — an all-ASCII append chain still
	// reports code units, and charAt still indexes them.
	let v = id("abc");
	v = v + id("d");
	if (v.length != 4 || v.charAt(2) != "c") {
		console.log("GUARD RED: ascii fast path broken, length=" + v.length + " charAt(2)=" + v.charAt(2));
		failures = failures + 1;
	}

	// Indexing past a multi-byte character stays in UTF-16 space.
	const w = id("aé");
	if (w.length != 2 || w.charAt(1) != "é") {
		console.log("GUARD RED: non-ascii charAt, length=" + w.length + " charAt(1)=" + w.charAt(1));
		failures = failures + 1;
	}

	if (failures == 0) console.log("GUARD-OK stringAsciiCacheStale");
	return failures;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
