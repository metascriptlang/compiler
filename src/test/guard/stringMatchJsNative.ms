// nim-guard: a string `match` with more arms than the hash threshold
//
// INVARIANT: hashing a string to reach a `switch` is a C code-generator
//   technique, not a shared lowering. Reference ccgstmts genStringCase hashes
//   because C can only switch on an integer constant, and it registers the hash
//   helper as a module dependency (cgsymValue) rather than naming it bare.
//   Reference jsgen genCaseJS switches on the string itself — no hash, no
//   threshold — because js switches on strings natively. Hashing on js is not a
//   trade-off, it is strictly more work: a full char loop, then the same
//   comparison the switch would have done anyway.
//
// WHAT IT CATCHES: the C-shaped hash lowering firing on js, which emitted a bare
//   `hashStringSigned(...)` that nothing pulls into the bundle —
//   "ReferenceError: hashStringSigned is not defined" the first time a match with
//   >8 string arms ran. PROVEN RED on the pre-fix binary at 9 arms and above,
//   green at 8, which is what makes the arm counts below the point of the guard.
//   Every arm count is exercised on BOTH backends: the C lane must keep hashing.
//
// GUARD-JS

function under(s: string): number {
	return match (s) {
		"a0" => 0, "a1" => 1, "a2" => 2, "a3" => 3,
		"a4" => 4, "a5" => 5, "a6" => 6, "a7" => 7,
		_ => -1,
	};
}

function over(s: string): number {
	return match (s) {
		"b0" => 0, "b1" => 1, "b2" => 2, "b3" => 3,
		"b4" => 4, "b5" => 5, "b6" => 6, "b7" => 7,
		"b8" => 8, "b9" => 9, "b10" => 10, "b11" => 11,
		_ => -1,
	};
}

// Multiple patterns on one arm, and a guard-free wildcard, still routed through
// the same switch builder — the arm shape the bucket loop duplicates bodies for.
function grouped(s: string): string {
	return match (s) {
		"c0" | "c1" => "low",
		"c2" | "c3" => "mid",
		"c4" | "c5" => "high",
		"c6" => "six", "c7" => "seven", "c8" => "eight", "c9" => "nine",
		_ => "none",
	};
}

function main(): void {
	console.log("under=" + under("a3") + "," + under("a7") + "," + under("zz"));
	console.log("over=" + over("b0") + "," + over("b11") + "," + over("zz"));
	console.log("grouped=" + grouped("c1") + "," + grouped("c5") + "," + grouped("c9") + "," + grouped("zz"));

	if (under("a3") !== 3) { throw "GUARD RED: below the threshold, first arms"; }
	if (under("a7") !== 7) { throw "GUARD RED: below the threshold, last arm"; }
	if (under("zz") !== -1) { throw "GUARD RED: below the threshold, wildcard"; }

	if (over("b0") !== 0) { throw "GUARD RED: above the threshold, first arm"; }
	if (over("b11") !== 11) { throw "GUARD RED: above the threshold, last arm"; }
	if (over("zz") !== -1) { throw "GUARD RED: above the threshold, wildcard"; }

	if (grouped("c1") !== "low") { throw "GUARD RED: grouped patterns, first group"; }
	if (grouped("c5") !== "high") { throw "GUARD RED: grouped patterns, last group"; }
	if (grouped("c9") !== "nine") { throw "GUARD RED: grouped patterns, single arm"; }
	if (grouped("zz") !== "none") { throw "GUARD RED: grouped patterns, wildcard"; }

	console.log("GUARD-OK");
}

main();
