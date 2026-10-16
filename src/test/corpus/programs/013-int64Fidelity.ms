// @stdout: int64-fidelity all-ok
// Oracle program — an int64 must survive the WHOLE pipeline exactly: source
// literal → AST → codegen → runtime arithmetic → toString. 012-floatFormat pins
// the float side; this pins the integer side.
//
// Every value here is above 2^53 on purpose: below that a double is exact and
// each check passes vacuously. The three stages fail independently, so they are
// probed independently — a single "print a big number" test cannot tell which
// stage lost the digits.
//
// Literals go through opaque() so constant folding cannot fold the check into a
// double and answer it before codegen. Byte-compare across the C lanes is not an
// oracle on its own — every lane can be wrong the same way — so the program
// grades itself and reports through BOTH the exit code and the summary line.

import { exit } from "std/process";

let failures: int32 = 0;

function opaque(v: int64): int64 {
	return v;
}

function check(label: string, ok: boolean): void {
	if (!ok) failures = failures + 1;
	console.log(label + "=" + (ok ? "ok" : "BAD"));
}

function main(): void {
	// Stage 1 — the literal itself. No toString involved: if the AST kept the
	// digits, the difference is exactly 1.
	check("litAbove2p53", opaque(9007199254740993) - opaque(9007199254740992) == 1);
	check("litAtInt64Max", opaque(9223372036854775807) - opaque(9223372036854775806) == 1);
	check("litNegative", opaque(-9007199254740993) + opaque(9007199254740992) == -1);
	// INT64_MIN reaches the AST as a positive magnitude that does not itself fit
	// int64, then a unary minus. Summing with INT64_MAX is exactly -1 and cannot
	// overflow, unlike the tempting max-minus-min.
	check("litInt64Min", opaque(-9223372036854775808) + opaque(9223372036854775807) == -1);

	// Stage 2 — runtime arithmetic. Built from values a double CAN hold, so this
	// isolates the arithmetic from the literal path.
	let x: int64 = 4503599627370496;
	x = x * 2 + 1;
	check("arithExact", x - opaque(9007199254740992) == 1);

	// String → int64 is the inverse of stage 3 and is exact on C (strtoll), so a
	// value can survive a full text round trip.
	check("parseIntExact", opaque("9007199254740993".parseInt()) - opaque(9007199254740992) == 1);
	check("parseIntMax", opaque("9223372036854775807".parseInt()) - opaque(9223372036854775806) == 1);

	// Stage 3 — int64 → string. x is exactly 2^53+1 by the check above.
	check("computedToString", x.toString() == "9007199254740993");
	check("computedConcat", ("v=" + x) == "v=9007199254740993");
	check("maxToString", opaque(9223372036854775807).toString() == "9223372036854775807");
	check("negToString", opaque(-9007199254740993).toString() == "-9007199254740993");
	check("minToString", opaque(-9223372036854775808).toString() == "-9223372036854775808");

	if (failures == 0) {
		console.log("int64-fidelity all-ok");
	} else {
		console.log("int64-fidelity failures=" + failures.toString());
		exit(1);
	}
}
main();
