// nim-guard: a Ref/Ptr branch join keeps the OWNING member, whatever the order
//
// INVARIANT: when joinBranchTypes collapses a {Ref<T>, Ptr<T>} pair to one
//   member, the surviving member is the Ref. The join type is what the analyzer
//   reads to decide ownership, so picking the Ptr turns a freshly allocated
//   branch into a borrow: nothing owns it, scope exit destroys it, and the
//   return increfs freed memory. Nim never faces the choice — commonType
//   (sem.nim:200-207) `return x` for a mismatched {tyRef, tyPtr} pair leaves a
//   type the later fit rejects, so no such join is ever accepted. MS accepts it
//   (the Ptr<T> cursor coercion, NIM-REF §4) and therefore owes the ownership
//   rule Nim gets for free.
// NIM-REF: "Branch-type join — pointer-kind pair" row.
//
// WHAT IT CATCHES: the join keeping the first branch instead of the owning one.
//   RED = wrong ids read back out of `kept` (measured 2000000 vs 1001000 on the
//   pre-fix binary; under ASan the same shape is a heap-use-after-free WRITE in
//   msIncRef). Twin: ptrRefBranchJoin.ms holds the safe Ref-first order, which
//   stays green under the buggy rule — branch ORDER is the whole signal.
//
// Signalling via the exit code, NOT `throw`: an uncaught throw exits 0 with no
// output on the C backend, so a throw-only guard can never go red here.
//
// GUARD-BALANCE Node2

class Node2 {
	id: int32;
	link: Ptr<Node2>;
}

function fresh(i: int32): Node2 {
	const n = new Node2();
	n.id = i;
	return n;
}

// The Ptr branch is FIRST on purpose: under "first branch wins" the join types
// `r` as a borrow and the fresh cell loses its owner.
function pickPtrFirst(arena: Node2[], i: int32, useBorrow: boolean): Node2 {
	const borrowed = arena[0].link;
	const r = useBorrow ? borrowed : fresh(i);
	return r;
}

function main(): number {
	const arena: Node2[] = [];
	const root = new Node2();
	root.id = 0;
	const second = new Node2();
	second.id = 1;
	root.link = second;
	arena.push(root);

	// Keep every result alive past the call that made it. A cell the join failed
	// to hand ownership of is destroyed at pickPtrFirst's scope exit, so the
	// array ends up holding dangling pointers: later allocations reuse the slots
	// (wrong id) and the array's own teardown decrefs them a second time.
	const kept: Node2[] = [];
	for (let i = 0; i < 2000; i++) {
		kept.push(pickPtrFirst(arena, i, i % 2 === 0));
	}
	let acc = 0;
	for (const k of kept) { acc = acc + k.id; }
	// 1000 borrowed steps (id 1) + the odd i in [0,2000) = 1000 + 1000000.
	if (acc !== 1001000) {
		console.log("GUARD RED: ptr-first Ref/Ptr join lost the owner, acc=" + acc.toString());
		return 1;
	}
	console.log("ptrFirstRefJoinOwnership ok");
	return 0;
}

const guardRc = main();
if (guardRc !== 0) process.exit(guardRc);
