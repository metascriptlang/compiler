// @maxrss: 30
// @stdout: strlit-union-field acc=700001
// note: String-literal-union interface fields (the yoga FlexStyle shape). Bug 1: pure strlit-union field (aliased/inline) classified RcKind.Named → <Alias>Destroy/<Alias>Copy prototypes for a type codegen represents as msString (genUnionType) → C compile error 'unknown type name'. Fix: classifyType Union arm routes isAllStringLiteralUnion through the String classification (msStringDecref family). Bug 2: `strlit-union | null` — createUnion flattens to [Lit, Lit, Null] so resolveAnnotation's 2-member Maybe detection misses it → codegen builds a real msUnion_* struct while expression sites emit msString ops → C type mismatch. Fix: isMaybeWrappable accepts StringLiteral + all-strlit unions (they are msString at runtime, no spare null bit → Maybe wrapper), maybeCacheKey gets a structural key for anonymous strlit unions. Churn loop guards the DRC side: field init/copy/scope-destroy of msString-repr values stays flat.

// String-literal-union interface fields — the FlexStyle shape (yoga bindings).
//
// Bug 1: a pure string-literal union field (aliased or inline) classified as
// RcKind.Named → emits <Alias>Destroy/<Alias>Copy prototypes for a type name
// codegen never typedefs (genUnionType represents pure strlit unions as
// msString) → C compile error "unknown type name".
//
// Bug 2: `strlit-union | null` — createUnion flattens to [Lit, Lit, Null], so
// the 2-member Maybe detection in resolveAnnotation misses it → codegen builds
// a real msUnion_* struct while expression sites emit msString ops → C type
// mismatch. Fix: isMaybeWrappable accepts StringLiteral + all-strlit unions.
//
// The churn loop guards the DRC side: field init/copy/scope-destroy of the
// msString-repr values must stay flat (RSS bound catches a per-iteration leak).

type FlexDirection = "column" | "column-reverse" | "row" | "row-reverse";

interface FlexStyle {
	flexDirection: FlexDirection;
	justify: ("flex-start" | "center") | null;
	altDirection: FlexDirection | null;
	width: float32 | null;
}

function pick(i: int32): FlexDirection {
	if (i % 2 == 0) return "row";
	return "column";
}

function main(): void {
	let acc = 0;
	let i = 0;
	while (i < 200000) {
		const s: FlexStyle = { flexDirection: pick(i), justify: "center", width: 10.5 };
		if (s.flexDirection == "row") { acc += 1; }
		if (s.justify != null) {
			if (s.justify == "center") { acc += 1; }
		}
		if (s.altDirection == null) { acc += 1; }
		if (s.width != null) { acc += 1; }
		i += 1;
	}
	let d: FlexDirection = "column";
	d = "row-reverse";
	if (d == "row-reverse") { acc += 1; }
	console.log("strlit-union-field acc=" + acc.toString());
}

main();
