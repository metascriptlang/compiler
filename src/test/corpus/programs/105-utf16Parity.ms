// Parity program — UTF-16 .length / charCodeAt semantics pinned across every
// lane (C drc/orc/danger ↔ JS). Astral chars (😀) must count as 2 units and
// split into surrogate halves; é stays 1 unit. Every string passes through
// id() so no lane can constant-fold the answers at compile time. Also walks
// the ASCII→non-ASCII append transitions so the runtime's cached-ASCII flag
// composition is exercised on both directions.

function id(s: string): string { return s; }

function main(): void {
	let s = id("ab");
	s = s + id("c");
	console.log("L1=" + s.length);
	s = s + id("😀");
	console.log("L2=" + s.length);
	console.log("cc3=" + s.charCodeAt(3));
	console.log("cc4=" + s.charCodeAt(4));

	const t = id("aé😀b");
	console.log("L3=" + t.length);
	console.log("cc1=" + t.charCodeAt(1));

	let u = id("xy");
	u = u + id("z");
	console.log("L4=" + u.length);
	u = u + id("é");
	console.log("L5=" + u.length);

	let w = id("");
	for (let i = 0; i < 100; i++) { w = w + id("é"); }
	console.log("L6=" + w.length);
	w = w + id("😀");
	console.log("L7=" + w.length);
}
main();
