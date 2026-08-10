// nim-guard: the matcher that ACCEPTS a string->cstring conversion must also INSERT it
//
// INVARIANT: Nim grades `formal cstring` against `actual string` as
//   isConvertible (sigmatch.nim:1627, comment "conversion from string to
//   cstring is automatic") and the same machinery that accepted the candidate
//   wraps the argument — paramTypesMatch calls implicitConv (sigmatch.nim:2179).
//   Relation and conversion are one step; there is no state where a call
//   resolved but its argument stayed unconverted.
// NIM-REF: rows 76/80 — MS runs two relations where Nim runs one. `isAssignable`
//   had the rule (compat.ms:354/:373, needsStdConv:441 names the conversion),
//   `typeRelation` did not, so the overload path rejected what assignment took.
//
// WHAT IT CATCHES: half of the pair regressing. Without the relation arm the
//   checker reports "No matching overload"; without the winner-path coercion
//   clang reports msString against const char*. Both are build failures.

function take(s: cstring): number { return 1; }
function take(n: number): number { return 2; }

function main(): void {
	const viaCString = take("hi");
	const viaNumber = take(42);
	console.log(viaCString);
	console.log(viaNumber);
	if (viaCString !== 1) { throw "GUARD RED: string literal did not select the cstring overload"; }
	if (viaNumber !== 2) { throw "GUARD RED: number did not select the number overload"; }
	console.log("cstringOverloadConv ok");
}
main();
