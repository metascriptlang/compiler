// nim-guard: whether a literal field is sunk or borrowed follows its declaration, not its position
//
// INVARIANT (injectdestructors.nim p(), nkObjConstr arm: lookupFieldAgain(t, sym) finds
//   the field by symbol, then a cursor field is walked `normal`, an owning one `sinkArg`):
//   a Cursor<T> field takes a borrow and an owning field takes its own reference,
//   whatever order the literal lists them in and whichever optional fields it omits.
//
// WHAT IT CATCHES: the field looked up by the literal's property index, which borrows
//   into the owning field and increfs the cursor one (DOUBLE-DESTROY of CkLeaf).
//
// RED MEANS: object-literal field modes drifted from Nim. Run /trace-nim on
//   processObjectLiteral / isPtrField in inject.ms.
// GUARD-BALANCE CkLeaf
// GUARD-JS

class CkLeaf { v: string; constructor(v: string) { this.v = v; } }
interface CkReordered { owner: CkLeaf; peer: Cursor<CkLeaf>; }
interface CkOptional { label?: string; peer: Cursor<CkLeaf>; owner: CkLeaf; }

function reordered(a: CkLeaf, b: CkLeaf): CkReordered { return { peer: b, owner: a }; }
function optional(a: CkLeaf, b: CkLeaf): CkOptional { return { peer: b, owner: a }; }

function run(): string {
	const a = new CkLeaf("a" + 1);
	const b = new CkLeaf("b" + 2);
	const r = reordered(a, b);
	const o = optional(a, b);
	return r.owner.v + r.peer.v + o.owner.v + o.peer.v;
}

if (run() == "a1b2a1b2") {
	console.log("GUARD-OK");
} else {
	process.exit(1);
}
