// A spread of a borrowed struct holding a plain closure or a class stays refused
//
// INVARIANT (ULTRALOCK views): only plain data and Sendable closures make a spread of a view an
//   owned copy (spreadOfSendableViewRuns.ms). A closure that is not Sendable, or a class
//   reference, is shared with the view, so a Sendable function that reaches it is refused.
//
// RED MEANS: the Sendable-leaf exemption of spreadCopiesRefFree widened past Sendable closures.
//
// GUARD-CHECK-FAIL into the field

class Node { v: int32 = 0; }
struct Plain { f: (n: int32) => int32; }
struct Holder { node: Node; }

class Box1 { p: Plain; constructor(p: Plain) { this.p = p; } }
class Box2 { h: Holder; constructor(h: Holder) { this.h = h; } }

function keepPlain(p: Readonly<Plain>): Box1 {
	return new Box1({ ...p });
}

function keepHolder(h: Readonly<Holder>): Box2 {
	return new Box2({ ...h });
}

function make(p: Plain): Sendable<() => int32> {
	return (): int32 => keepPlain(p).p.f(1); // GUARD-REFUSED
}

function make2(h: Holder): Sendable<() => int32> {
	return (): int32 => keepHolder(h).h.node.v; // GUARD-REFUSED
}
