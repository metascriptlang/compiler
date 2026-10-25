// @exit: 1
// @stdout: kept 1
// @stdout: none null
// @stdout: invalid union conversion: "fixed" is not Narrow
// @xfail(danger): --danger drops the conversion check, so the value outside Narrow reaches the match instead of stopping
// @xfail(raiser): the Raiser stops at the same conversion with exit 1, but its 'raiser runtime error: invalid union conversion: …' goes to stderr, which the raiser cell keeps apart from the compared output; src/codegen/raiser/eval.ms pins it
// note: `as` from a wider string-literal union into a narrower one is checked at run time: a value Narrow lacks stops with "invalid union conversion" where it used to reach an exhaustive match as a lie (0 on C, undefined on JS).

type Wide = "static" | "relative" | "absolute" | "fixed";
type Narrow = "static" | "relative" | "absolute";

function toC(v: Narrow): int32 {
	return match (v) {
		"static" => 0 as int32,
		"relative" => 1 as int32,
		"absolute" => 2 as int32,
	};
}

function read(v: Wide | null): Wide | null { return v; }
function narrow(v: Wide | null): Narrow | null { return v as Narrow | null; }

function main(): void {
	const kept = narrow(read("relative"));
	if (kept !== null) console.log("kept", toC(kept));
	console.log("none", narrow(read(null)));
	const n = narrow(read("fixed"));
	if (n !== null) console.log("to", toC(n));
	console.log("unreachable");
}

main();
