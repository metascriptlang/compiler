// nim-guard: overload matching and assignment must run ONE type relation
//
// INVARIANT (Nim): parameter matching has a single relation — `typeRel`
//   (sigmatch.nim). `paramTypesMatch` scores candidates with it and `fitNode`
//   (sem.nim:99 -> indexTypesMatch) enforces the SAME relation at every
//   assignment site, so a pair that is assignable is by construction also
//   matchable as an argument. Nim has no second, weaker relation that overload
//   resolution alone consults.
// NIM-REF: row 76 already records MS splitting Nim's single relation and names
//   `isAssignable` "an incomplete stand-in for Nim typeRel"; row 80 records
//   `typeRelation` as the relation used for scoring. The split is documented —
//   the two relations DISAGREEING on the same pair is not.
//   -> DIVERGE-UNINTENTIONAL.
//
// WHAT WENT WRONG: `typeRelation` was missing two rules `isAssignable` has —
//   StringLiteral -> String (isAssignable:362) and union-actual "every member
//   must relate" (isAssignable:406). So `Dir = "row" | "column"` passed to a
//   `string` parameter was accepted by a normal call and rejected as an operator
//   argument. Every string operator on a literal union then failed to resolve and
//   the token reached codegen, where clang got `msString == msString`.
//   `match` over string arms lowers through the derived `===` path, so this took
//   out every string-union match (yoga/src/enums.ms and with it Neon's style +
//   voidHost suites).
//
// WHAT IT CATCHES: removing either rule. The failure mode is a BUILD failure
//   (clang "invalid operands to binary expression ('msString' and 'msString')"),
//   so this guard goes red by failing to compile, not by throwing.

type Dir = "row" | "column";

function dirToOrdinal(v: Dir): int32 {
	return match (v) {
		"row" => 2,
		"column" => 0,
	};
}

function takesString(s: string): int32 { return 7; }

export function main(): void {
	const d: Dir = "row";
	const e: Dir = "row";
	const other: Dir = "column";
	const s: string = "row";

	// (1) the normal-call side of the relation — was always accepted
	const viaCall = takesString(d);
	console.log("viaCall=" + viaCall.toString());
	if (viaCall !== 7) { throw "GUARD RED: union no longer accepted at a string parameter"; }

	// (2) match over string-literal arms — lowers through the derived `===`
	const ord = dirToOrdinal(d);
	console.log("ord=" + ord.toString());
	if (ord !== 2) { throw "GUARD RED: match over a string-literal union mis-dispatched"; }

	// (3) equality, union vs union
	const eqUU = d === e;
	console.log("eqUU=" + eqUU.toString());
	if (!eqUU) { throw "GUARD RED: === on two string-literal unions is wrong"; }

	// (4) equality, union vs plain string
	const eqUS = d == s;
	console.log("eqUS=" + eqUS.toString());
	if (!eqUS) { throw "GUARD RED: == between a string-literal union and string is wrong"; }

	// (5) inequality must derive from the same base overload
	const neq = d !== other;
	console.log("neq=" + neq.toString());
	if (!neq) { throw "GUARD RED: !== on string-literal unions is wrong"; }

	// (6) ordering operators go through the same relation
	const lt = other < d;
	console.log("lt=" + lt.toString());
	if (!lt) { throw "GUARD RED: < on string-literal unions is wrong"; }

	// (7) plain string neighbours — must not regress
	const a: string = "ab";
	const b: string = "ab";
	console.log("plainEq=" + (a === b).toString());
	if (!(a === b)) { throw "GUARD RED: === on plain strings regressed"; }

	console.log("typeRelationStringUnion ok");
}

main();
