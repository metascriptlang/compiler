// A spread of a borrowed Vec of refs stays refused as storing the view
//
// INVARIANT (ULTRALOCK views): `[...view]` over class elements stores the same refs, so a Sendable
//   function that reaches it would share them with the task. Only spreads of ref-free elements pass
//   (spreadOfScalarViewRuns.ms).
//
// RED MEANS: the spread exemption widened to elements that hold a ref.
//
// GUARD-CHECK-FAIL into an array literal

class Node { v: int32 = 0; }

function keep(views: Readonly<Vec<Node>>): Vec<Readonly<Node>> {
	return [...views];
}

function make(views: Vec<Node>): Sendable<() => int32> {
	return (): int32 => keep(views).length as int32; // GUARD-REFUSED
}
