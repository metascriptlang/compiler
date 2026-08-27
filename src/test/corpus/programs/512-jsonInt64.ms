// @xfail(js): int64 IS a double on the JS backend — the BigInt representation
//   is gated off there (jsBigInt64, codegen/js) because the operator half of
//   the mapping is unwritten, so every int64 site on that backend is a Number
//   and the delta checks below read 0 instead of 1. Not a JSON bug and not
//   parser.ms's parseInt: that call is only where the loss becomes visible.
//   When the mapping ships (docs/JSON.md roadmap 3) and the gate flips on,
//   this XPASSes loud and the marker comes off.
// @stdout: int64-json all-ok
// Oracle program — int64 fidelity THROUGH the JSON surface, the one place the
// two backends deliberately diverge today with no corpus coverage.
// 013-int64Fidelity pins the language pipeline (literal → arith → toString);
// this pins the JSON pipeline: typed decode, stringify, text round trip, the
// untyped Int carrier, and the does-not-fit-int64 → Number-carrier rule.
//
// Every value sits above 2^53 so a double cannot hold it. Checks compare
// DELTAS (id - base === 1), never equality against a literal: on a lossy
// backend both sides of an equality round to the SAME double and pass
// vacuously — the delta reads 0 there and fails honestly. Byte-compare across
// the C lanes cannot judge this alone (all lanes could be wrong identically),
// so the program grades itself into the summary line that @stdout asserts.
// No std/process import on purpose: its .jms does not parse today, and a js
// build failure would satisfy the xfail for the WRONG reason.

interface Holder {
	id: int64;
}

let failures: int32 = 0;

function check(label: string, ok: boolean): void {
	if (!ok) failures = failures + 1;
	console.log(label + "=" + (ok ? "ok" : "BAD"));
}

function deltaOk(r: Result<Holder, string>, base: int64): boolean {
	if (r.ok) {
		return r.value.id - base === 1;
	}
	return false;
}

function main(): void {
	// Typed decode — exact strtoll on C (parser.ms parseNumber → parseInt).
	check("typedAbove2p53", deltaOk(JSON.parse<Holder>("{\"id\":9007199254740993}"), 9007199254740992));
	check("typedMax", deltaOk(JSON.parse<Holder>("{\"id\":9223372036854775807}"), 9223372036854775806));
	check("typedNeg", deltaOk(JSON.parse<Holder>("{\"id\":-9007199254740993}"), -9007199254740994));

	const mn = JSON.parse<Holder>("{\"id\":-9223372036854775808}");
	if (mn.ok) {
		check("typedMin", mn.value.id + 9223372036854775807 === -1);
	} else {
		check("typedMin", false);
	}

	// Decoded value → string: the print path must not round-trip a double.
	const a = JSON.parse<Holder>("{\"id\":9007199254740993}");
	if (a.ok) {
		check("decodedToString", a.value.id.toString() === "9007199254740993");
	} else {
		check("decodedToString", false);
	}

	// Stringify emits the exact digits, and the full text round trip survives.
	const h: Holder = { id: 9223372036854775807 };
	check("stringifyMax", JSON.stringify(h) === "{\"id\":9223372036854775807}");
	check("roundTrip", deltaOk(JSON.parse<Holder>(JSON.stringify(h)), 9223372036854775806));

	// Untyped tree — the Int carrier is exact through asInt64.
	const u = JSON.parseValue("{\"id\":9007199254740993}");
	if (u.ok) {
		const v: JsonValue = u.value;
		check("untypedAsInt64", v.getDynamicField("id").asInt64() - 9007199254740992 === 1);
	} else {
		check("untypedAsInt64", false);
	}

	// Does not fit int64 → Number carrier on BOTH backends (classified from
	// the digits, backend-independent), so a declared int64 field errors.
	const over = JSON.parse<Holder>("{\"id\":9223372036854775808}");
	check("overflowIsErr", !over.ok);
	const wide = JSON.parse<Holder>("{\"id\":98765432109876543210}");
	check("wideIsErr", !wide.ok);

	if (failures === 0) {
		console.log("int64-json all-ok");
	} else {
		console.log("int64-json failures=" + failures.toString());
	}
}

main();
