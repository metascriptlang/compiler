// nim-guard: comparing a union against a value of ONE member type
//
// INVARIANT: `u === 200` where `u: number | string | null` is TS surface syntax
//   with no Nim analog — Nim REFUSES the structural form. `system.nim:1973`
//   defines `==`*[T: tuple|object] over the PARALLEL `fields(x, y)` iterator, and
//   `semfields.nim:93-97` rejects that iterator on a case object ("parallel
//   'fields' iterator does not work for 'case' objects"). A tagged union is MS's
//   case object, so the reference offers no whole-union comparison to port: the
//   only sound reading is the TS one — NARROW the union to the member type the
//   other operand already has, then compare with that member's own `==`.
// NIM-REF: rows 96/100 — `T | null` is DIVERGE-INTENTIONAL (TS-compat). The
//   Maybe carrier is a C REPRESENTATION: js de-materializes it, so the carrier
//   Eq lowering must not fire there (there is no carrier and no generated body).
//
// WHAT IT CATCHES: the carrier Eq lowering firing on a backend that has no
//   carrier — "ReferenceError: Maybe_p0Eq is not defined" at run time. PROVEN
//   RED on the pre-fix binary for every cell below; the C lane is the neighbour
//   that must stay green (it does have the carrier and the generated body).
//   `=== null` and an absent carrier are the two presence cases: neither is a
//   member comparison, and both must survive the lowering unchanged.
//
//   A carrier whose payload is itself a tagged union (`number | string | null`)
//   compares two `msUnion_*` structs inside the generated body — not valid C.
//   Tags must agree, and a slot is only read when its own tag is live, so two
//   absent-or-inactive slots never compare their garbage.
//
// SCOPE: only the Maybe carrier. A general tagged union compared against one of
//   its members (`let u: number | string = 200; u === 200`) is still broken on C
//   — it reaches the backend un-narrowed and clang rejects
//   "invalid operands ('msUnion_*' and 'int')". That fix is narrow-then-compare
//   at the comparison site, and lands with its own cells here.
//
// GUARD-JS

function main(): void {
	let c: number | null = 200;
	let d: string | null = "x";
	let g: "row" | "column" | null = "column";
	let absent: number | null = null;

	console.log("c=" + (c === 200));
	console.log("d=" + (d === "x"));
	console.log("g=" + (g === "column"));
	console.log("presence=" + (c === null));
	console.log("absent=" + (absent === 200));

	if (!(c === 200)) { throw "GUARD RED: Maybe<number> vs number literal"; }
	if (!(d === "x")) { throw "GUARD RED: Maybe<string> vs string literal"; }
	if (!(g === "column")) { throw "GUARD RED: Maybe<string-literal union> vs literal"; }
	if (c === null) { throw "GUARD RED: presence test flipped"; }
	if (absent === 200) { throw "GUARD RED: an absent carrier compared equal to a member"; }
	if (c === 201) { throw "GUARD RED: unequal member compared equal"; }

	let w: number | string | null = 200;
	let sameW: number | string | null = 200;
	let pct: number | string | null = "50%";
	let samePct: number | string | null = "50%";
	let otherPct: number | string | null = "60%";
	let unset: number | string | null = null;
	let alsoUnset: number | string | null = null;

	console.log("w=" + (w === 200));
	console.log("pct=" + (pct === "50%"));
	console.log("crossTag=" + (w === pct));
	console.log("bothUnset=" + (unset === alsoUnset));

	if (!(w === 200)) { throw "GUARD RED: number slot of a union payload"; }
	if (!(w === sameW)) { throw "GUARD RED: two carriers holding the same number"; }
	if (!(pct === "50%")) { throw "GUARD RED: string slot of a union payload"; }
	if (!(pct === samePct)) { throw "GUARD RED: two carriers holding the same string"; }
	if (pct === otherPct) { throw "GUARD RED: different strings compared equal"; }
	if (w === pct) { throw "GUARD RED: different tags compared equal"; }
	if (w === "50%") { throw "GUARD RED: number slot matched a string literal"; }
	if (!(unset === alsoUnset)) { throw "GUARD RED: two absent payloads compared unequal"; }
	if (unset === w) { throw "GUARD RED: an absent payload matched a live one"; }

	console.log("GUARD-OK");
}

main();
