// What a Sendable function itself does stays refused beside a call to a captured actor
//
// INVARIANT (ULTRALOCK actors): skipping an actor method's body for the closure's crossing check
//   does not loosen the closure's own body or the message's arguments: a captured view stored into a
//   container, a function value called here and a mutable Vec sent to the actor all stay refused.
//
// RED MEANS: the actor-call exemption covers more than the callee's body.
//
// GUARD-CHECK-FAIL stores the view 'node' into an array literal
// GUARD-CHECK-FAIL calls a function value
// GUARD-CHECK-FAIL actor methods only accept value types

class Node { v: int32 = 0; }
actor Hub {
	n: int32 = 0;
	kept: Vec<Node> = [];
	bump(): int32 { this.n += 1; return this.n; }
	keep(v: Vec<Node>): void { this.kept = v; }
}

function storesView(hub: Hub, node: Node): Sendable<() => Node[]> {
	return (): Node[] => { hub.bump(); return [node]; }; // GUARD-REFUSED
}

function callsFnValue(hub: Hub, f: (x: int32) => int32): Sendable<() => int32> {
	return (): int32 => { hub.bump(); return f(1); }; // GUARD-REFUSED
}

function sendsView(hub: Hub, views: Vec<Node>): Sendable<() => void> {
	return (): void => { hub.keep(views); }; // GUARD-REFUSED
}
