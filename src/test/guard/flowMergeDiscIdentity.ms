// nim-guard: flow-merge keeps DU variants distinct (type identity is structural)
//
// INVARIANT (reference): type IDENTITY and type ASSIGNABILITY are two different
//   relations. Identity for an anonymous aggregate compares field names + field
//   types pairwise (types.nim `sameTuple`, called from `sameTypeAux` of tyTuple);
//   named object types compare nominally by id (`ifFastObjectTypeCheckFailed`).
//   A control-flow join that dedups branch types must use IDENTITY — two DU
//   variants are distinct types and must both survive the merge.
// NIM-REF: row "Structural type-dedup keys" — verdict DIVERGE-UNINTENTIONAL ->
//   SAME ("type identity is structural everywhere"). Same class of bug: a key /
//   relation that collapses structurally-different types into one.
//
// WHAT IT CATCHES: `typeRelation`'s Struct arm (checker/compat.ms) compared
//   `typeName` only. Both variants of a match-type DU are anonymous (name ""),
//   so `{kind,a}` and `{kind,b}` reported Exact. The BranchLabel merge
//   (checker/flow.ms getTypeAtBranchLabel) dedups antecedents with
//   `typeRelation === Exact` and therefore collapsed the two edges of
//   `d.kind === K.Alpha && …` to the head antecedent — the TRUE branch's
//   variant. Every later read of `d` then used the wrong variant. The sibling
//   half: rebuilding the merged union must go through
//   `unionPreservingDiscriminant`, or the residual loses its discriminant
//   metadata and disc reads can no longer route to `_tag`.
//
// RED MEANS: a narrowing leaked past the sub-expression that created it, or the
//   merged union lost its disc metadata. Pre-fix this probe FAILS TO BUILD:
//   "no member named 'kind' in 'struct FmEnumDU'" — codegen routes the disc read
//   against a variant struct that has no disc field. Run /trace-nim on
//   typeRelation (checker/compat.ms) + getTypeAtBranchLabel (checker/flow.ms).
//   Proven RED on the pre-fix binary, GREEN post-fix (drc + orc).
//
// SHAPE: enum-disc match type — its variants have DIFFERENT layouts, so the
//   collapse is observable. A bool-disc DU cannot serve here: both variants
//   carry `ok` at the same offset, so a leaked narrow still emits valid C.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

enum FmK { Alpha, Beta }
type FmEnumDU = match (kind: FmK) { FmK.Alpha => { a: int32 }, FmK.Beta => { b: string } };

function mkBeta(): FmEnumDU { return { kind: FmK.Beta, b: "beta" }; }
function mkAlpha(): FmEnumDU { return { kind: FmK.Alpha, a: 7 }; }

// The `&&` narrows `d` to the Alpha variant inside its right operand only.
// After the expression, `d` must be the full union again.
function classifyAfterAnd(d: FmEnumDU): int32 {
	const probe = (d.kind === FmK.Alpha) && true;
	if (d.kind === FmK.Beta) return 2;
	return 1;
}

function classifyAfterOr(d: FmEnumDU): int32 {
	const probe = (d.kind === FmK.Alpha) || false;
	if (d.kind === FmK.Beta) return 2;
	return 1;
}

function main(): int32 {
	if (classifyAfterAnd(mkBeta()) !== 2) { console.log("GUARD-FAIL and/beta"); return 1; }
	if (classifyAfterAnd(mkAlpha()) !== 1) { console.log("GUARD-FAIL and/alpha"); return 1; }
	if (classifyAfterOr(mkBeta()) !== 2) { console.log("GUARD-FAIL or/beta"); return 1; }
	if (classifyAfterOr(mkAlpha()) !== 1) { console.log("GUARD-FAIL or/alpha"); return 1; }
	console.log("GUARD-OK flowMergeDiscIdentity");
	return 0;
}
