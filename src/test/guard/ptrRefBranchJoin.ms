// nim-guard: branch join of {Ref<T>, Ptr<T>} collapses to one pointer member
//
// INVARIANT: joinBranchTypes/canonicalizeBranchJoin treat a Ref<T>/Ptr<T> pair
//   over the SAME pointee as ONE member, and the surviving member is the owning
//   Ref regardless of branch order (see ptrFirstRefJoinOwnership.ms for why the
//   order matters). Nim's commonType (sem.nim:200-207) instead leaves a
//   mismatched {tyRef, tyPtr} pair as a type the later fit rejects; MS accepts
//   the pair under the Ptr<T> cursor coercion (NIM-REF §4). fitJoinedBranch
//   coerces the other branch via the intentional Ref<->Ptr cursor coercion
//   (NIM-REF §4). A ternary/array-literal join over a Ptr<T> linked-list field
//   must NOT mint a tagged union.
// NIM-REF: "Branch-type join — pointer-kind pair" row (2026-08-14).
//
// WHAT IT CATCHES: the join regressing to union {Ref<T>, Ptr<T>} — RED = C
//   build failure (msUnion_* returned as Tok* / pushed into Tok[], the
//   preprocess.ms copyLine shape) or wrong value. Proven RED on the pre-fix
//   binary; GREEN post-fix. Acceptance twin: src/module/cparse/preprocess.ms
//   copyLine ternary (the deleted if-form workaround must stay deleted).
//
// No RC balance directive — signal is build-failure / wrong-value-throw.

class Tok {
	kind: int32;
	next: Ptr<Tok>;
}

function pick(tok: Tok): Tok {
	const rest = tok.kind == 0 ? tok : tok.next;
	return rest;
}

function pickPair(tok: Tok): Tok[] {
	const rest = tok.kind == 0 ? tok : tok.next;
	return [tok.next, rest];
}

function main(): void {
	const e = new Tok();
	e.kind = 99;
	const t = new Tok();
	t.kind = 1;
	t.next = e;
	if (pick(t).kind != 99) { throw "GUARD RED: ternary Ref/Ptr join wrong value"; }
	const pair = pickPair(t);
	if (pair[1].kind != 99) { throw "GUARD RED: array-literal Ref/Ptr join wrong value"; }
	console.log("ptrRefBranchJoin ok");
}
main();
