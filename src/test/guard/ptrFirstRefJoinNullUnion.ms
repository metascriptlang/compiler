// nim-guard: the owning-member rule also holds on the null-union join path
//
// INVARIANT: canonicalizeBranchJoin rebuilds a join that carried a `null`
//   member, and its dedup loop must apply the SAME rule as joinBranchTypes —
//   a {Ref<T>, Ptr<T>} pair over one pointee collapses to the owning Ref,
//   whatever the branch order. It is a second, independently reachable copy of
//   that loop: a `T | null` result routes here instead, so fixing only
//   joinBranchTypes leaves the bug alive behind a nullable return type.
// NIM-REF: "Branch-type join — pointer-kind pair" row.
//
// WHAT IT CATCHES: the null-union path keeping the first branch. RED on the
//   pre-fix binary is louder than the non-null twin — the ledger aborts with
//   DOUBLE-DESTROY of JoinNode (rc=134) and the ids read back wrong. Twin:
//   ptrFirstRefJoinOwnership.ms covers the same rule without a null member.
//
// Signalling via the exit code, NOT `throw`: an uncaught throw exits 0 with no
// output on the C backend, so a throw-only guard can never go red here.
//
// GUARD-BALANCE JoinNode

class JoinNode {
	id: int32;
	link: Ptr<JoinNode>;
}

function fresh(i: int32): JoinNode {
	const n = new JoinNode();
	n.id = i;
	return n;
}

// Ptr branch first, and a third arm contributing `null` so the join is rebuilt
// by canonicalizeBranchJoin rather than returned straight from joinBranchTypes.
function pick(arena: JoinNode[], i: int32, mode: int32): JoinNode | null {
	const borrowed = arena[0].link;
	const r = mode == 0 ? borrowed : (mode == 1 ? fresh(i) : null);
	return r;
}

function main(): number {
	const arena: JoinNode[] = [];
	const root = new JoinNode();
	root.id = 0;
	const second = new JoinNode();
	second.id = 1;
	root.link = second;
	arena.push(root);

	const kept: JoinNode[] = [];
	for (let i = 0; i < 3000; i++) {
		const p = pick(arena, i, i % 3);
		if (p != null) { kept.push(p); }
	}
	let acc = 0;
	for (const k of kept) { acc = acc + k.id; }
	// 1000 borrowed steps (id 1) + the fresh ids 1,4,…,2998 = 1000 + 1499500.
	if (acc != 1500500) {
		console.log("GUARD RED: null-union Ref/Ptr join lost the owner, acc=" + acc.toString());
		return 1;
	}
	console.log("ptrFirstRefJoinNullUnion ok");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
