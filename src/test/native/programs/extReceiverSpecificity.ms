// Extension overload receiver specificity: a concrete receiver must beat the
// catch-all `this unknown` — the catch-all's PRESENCE must not poison
// resolution. Scoring strips the receiver param, so without the specificity
// pre-filter `tag(this string)` vs `tag(this unknown)` tie into "Ambiguous
// call" — historically swallowed inside generic instantiation body-checks and
// emitted as argument-less C calls (the Map.get key.hash() bug when std adds
// hash(this unknown)).
//
// Catch-all receivers remain callable only with pointer-shaped receivers
// (Ptr<T> → void*) — passing value structs to `this unknown` is a separate
// pre-existing C-backend gap, deliberately not exercised here.

export function tag(this s: string): string { return "str:" + s; }
export function tag(this u: unknown): string { return "any"; }

function describe<T>(x: T): string {
	return x.tag();
}

function main(): void {
	let ok = true;
	if ("abc".tag() !== "str:abc") { ok = false; }
	if (describe("xyz") !== "str:xyz") { ok = false; }
	if (ok) {
		console.log("ext-receiver-specificity PASS");
	} else {
		console.log("ext-receiver-specificity FAIL " + "abc".tag() + " " + describe("xyz"));
	}
}

main();
