// Differential program — `T | null` observable semantics must be identical on
// C and JS. C represents nullable value types as a Maybe struct { value, present };
// JS uses native null (maybeUnwrap pass). This program's stdout is the contract:
// the two backends must print byte-identical output.
//
// @xfail(c): bare `number | null` Maybe-carrier miscompiles (double != void*) — open G1 cluster, docs/TSGAP.md "G1-gate" (siblings bug010/bug047). XPASS fires loud when the fix lands.
// @xfail(san): same G1 carrier — the san cell builds the same C (drc) and fails identically.

interface Box { label: string; }

function pickNum(x: number, on: boolean): number | null {
	if (on) { return x; }
	return null;
}
function pickBox(on: boolean): Box | null {
	if (on) { return { label: "hi" }; }
	return null;
}

function main(): void {
	// value-type nullable — narrow then use
	const a = pickNum(42, true);
	const b = pickNum(7, false);
	if (a !== null) { console.log("a=" + a); } else { console.log("a absent"); }
	if (b !== null) { console.log("b=" + b); } else { console.log("b absent"); }

	// reference-type nullable — field access after narrow
	const p = pickBox(true);
	const q = pickBox(false);
	if (p !== null) { console.log("p.label=" + p.label); } else { console.log("p absent"); }
	if (q !== null) { console.log("q.label=" + q.label); } else { console.log("q absent"); }

	// nullable in boolean / ternary context
	console.log(a !== null ? "a truthy" : "a falsy");
	console.log(b !== null ? "b truthy" : "b falsy");
}
main();
