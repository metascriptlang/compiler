// `field?: T` desugars to `(T) | null`: omission stores null, a narrow
// restores T. This is the TS optional-property surface mapped onto the
// existing nullable-union model - the requiresInit rule for bare function
// fields is untouched, `?` is the opt-out. Cross-lane byte compare pins
// C/JS parity; the SAN lane pins the DRC ledger for the Maybe payloads.
// (js lane enabled 2026-09-01: copy-on-read now sees through the Maybe
// carrier to the erased `T | null` payload — no more "[object Object]".)

interface Box { a: int32; cb?: (x: int32) => int32; }
interface Cfg { title?: string; width?: number; tags?: string[]; }

function useBox(b: Box): string {
	if (b.cb !== null) { return "cb=" + b.cb(20).toString(); }
	return "cb=null";
}

function pick(p: { when: boolean; fb?: string }): string {
	if (p.fb !== null) { return p.fb; }
	return "d";
}

function main(): void {
	const omit: Box = { a: 1 };
	const has: Box = { a: 2, cb: (x: int32) => x * 2 + 2 };
	console.log(useBox(omit));
	console.log(useBox(has));

	const c1: Cfg = {};
	const c2: Cfg = { title: "t", width: 3.5, tags: ["x", "y"] };
	console.log("t=" + (c1.title === null ? "null" : "set")
		+ " w=" + (c1.width === null ? "null" : "set")
		+ " g=" + (c1.tags === null ? "null" : "set"));
	let w = "none";
	if (c2.width !== null) { w = c2.width.toString(); }
	let tg = "none";
	if (c2.tags !== null) { tg = c2.tags.length.toString(); }
	console.log("t2=" + (c2.title !== null ? c2.title : "?") + " w2=" + w + " g2=" + tg);

	console.log("p1=" + pick({ when: true, fb: "hit" }) + " p2=" + pick({ when: false }));
}

main();
