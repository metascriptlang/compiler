// A plain parameter cannot be moved, and `msc check` says so with the fix
//
// INVARIANT (LANG.md move semantics): `move p` promises no copy is made, and a plain parameter is
//   borrowed from the caller, so moving it would copy it. The checker refuses it for a function or a
//   method parameter of a type that carries a reference, in an ordinary call, an actor constructor and
//   a method call alike, and names `sink` as the declaration that takes ownership. A sink parameter,
//   a constructor parameter and a parameter the body reassigns still move (moveOfParamAccepted.ms).
//
// RED MEANS: the check stopped refusing, so only the C build reports it and with a wrong reason.
//
// GUARD-CHECK-FAIL declare the parameter `sink` to take ownership

class Node { v: int32 = 0; }
struct Hooks { run: (n: int32) => int32; }

actor Holder {
	hooks: Hooks;
	constructor(hooks: Hooks) { this.hooks = hooks; }
}

function consume(sink h: Hooks): int32 { return h.run(1); }
function consumeNode(sink n: Node): int32 { return n.v; }

class Box {
	h: Hooks;
	constructor(h: Hooks) { this.h = h; }
	put(h: Hooks): void { this.h = move h; } // GUARD-REFUSED
}

function viaCall(h: Hooks): int32 {
	return consume(move h); // GUARD-REFUSED
}

function viaActor(hooks: Hooks): Holder {
	return new Holder(move hooks); // GUARD-REFUSED
}

function viaClass(n: Node): int32 {
	return consumeNode(move n); // GUARD-REFUSED
}
