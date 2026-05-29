// OPEN BUG (xfail) — heap-allocated string through an actor field corrupts.
//
// Found by this tier: setting an actor string field to a HEAP-concatenated
// value (not a string literal) and reading it back via an actor CALL returns
// garbage — the field aliases a freed/reused buffer. A string LITERAL round-
// trips fine, which is why paralock-nested (literal tag) passed and masked it.
// This is the std/http multi-WS broadcast string path (PARALOCK §7.6).
//
// Pre-existing at HEAD (verified by reverting the uncommitted actor WIP — still
// failed). Correctness bug: exits 0, leaks/crashes nothing, just returns the
// wrong string — so it is caught by expectStdout, not by exit/RSS. Drop the
// xfail when the actor heap-string transfer is fixed.

actor Box {
	tag: string = "";
	setTag(s: string): void { this.tag = s; }
	getTag(): string { return this.tag; }
}

function makeHeapStr(): string {
	let s = "topic-";
	s = s + "room-" + "payload";   // heap concat, not a literal
	return s;
}

function main(): void {
	const b = new Box();
	b.setTag(makeHeapStr());
	const t = await b.getTag();
	if (t !== "topic-room-payload") { console.log(`FAIL tag=[${t}]`); return; }
	console.log("PASS:actor-heapstr");
}
