// nim-guard: an empty array literal finding its element type through `T[] | null`
//
// INVARIANT: an ArrayLiteral checked against a nullable-array expectation must
//   peel the union to its array member before element inference — the union
//   counterpart of the ArrayLiteral arm's Ref<Array> peel, itself the analog of
//   semArrayConstr's expectedType.skipTypes(abstractRange). On the write side, a
//   member-expr assignment LHS takes its DECLARED type, not the flow-narrowed
//   one — the identifier arm's leftPartOfAsgn rule applied to the member write:
//   inside `if (n.f === null) { n.f = [] }` the narrowed type is `null`, which
//   can never donate an element type.
//
// WHAT IT CATCHES: "internal: unresolved type (kind=47) reached codegen" — the
//   empty literal carries its pending element type to the C emission gate (js
//   stays green: it de-materializes the carrier). PROVEN RED on the pre-fix
//   binary for BOTH shapes below, and each shape needs BOTH rules. Simpler
//   forms (a bare `P[] | null` local, a single-field carrier) went green from
//   unrelated drift — the recursive child array and the second nullable field
//   are what keep these red, so they stay.

interface P1 { name: string }
interface RecNode { children: RecNode[]; dyn: P1[] | null }

function withDynRec(n: RecNode, name: string): RecNode {
	if (n.dyn === null) { n.dyn = []; }
	(n.dyn as P1[]).push({ name });
	return n;
}

type SV = number | string | null;
interface P2 { name: string; get: () => SV }
interface FlatNode { dyn: P2[] | null; region: (() => void) | null }

function withDynFlat(n: FlatNode, name: string, get: () => SV): FlatNode {
	if (n.dyn === null) { n.dyn = []; }
	(n.dyn as P2[]).push({ name, get });
	return n;
}

function main(): void {
	const rec = withDynRec({ children: [], dyn: null }, "w");
	const flat = withDynFlat({ dyn: null, region: null }, "w", () => 5);
	console.log("recLen=" + (rec.dyn as P1[]).length.toString());
	console.log("flatLen=" + (flat.dyn as P2[]).length.toString());
	console.log("GUARD-OK");
}
main();
