// @maxrss: 30
// @stdout: generic-narrowing PASS
// note: Early-return null narrowing inside a monomorphized generic body. monoCloneNode creates nodes via createNodeAt (flowNode=null everywhere), so flow-graph narrowing queries in the instantiation body re-check silently fell back to declared types: `if (cur === null) return 0;` did not narrow the fall-through path (then-branch narrowing uses the checker guard stack and still worked, masking the gap) -> 'got Ptr | null, expected Ptr'. Fix: bindFunctionFlow(clone) rebuilds the flow graph for the cloned body before callCheckFunctionBody (instantiate.ms, both the function and class-ctor paths).

// Early-return null narrowing inside a monomorphized generic body.
//
// Monomorphized clones are created via createNodeAt (flowNode=null on every
// node), so flow-graph narrowing queries in the instantiation body re-check
// silently fell back to declared types: `if (cur === null) return 0;` did not
// narrow `cur` on the fall-through path → "got Ptr | null, expected Ptr".
// Fixed by bindFunctionFlow(clone) before callCheckFunctionBody.

interface Holder { p: Ptr<void> | null; }

function takePtr(p: Ptr<void>): int32 { return 7; }

export function probeGet(this h: Holder): Ptr<void> | null { return h.p; }

function grab<T>(h: T): int32 {
	const cur = h.probeGet();
	if (cur == null) return 0;
	return takePtr(cur);
}

function main(): void {
	const a: Holder = { p: null };
	if (grab(a) == 0) {
		console.log("generic-narrowing PASS");
	} else {
		console.log("generic-narrowing FAIL");
	}
}

main();
