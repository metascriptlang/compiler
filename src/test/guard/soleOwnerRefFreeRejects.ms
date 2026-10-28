// A value whose type can hold a ref stays refused by the sole-owner rule
//
// INVARIANT (ULTRALOCK custody, E148): `move` of a parameter, or of a copy that is not fresh, into
//   an actor call is refused when the type holds a class, a closure or a Vec of either, because the
//   caller may still reach that graph. Ref-free types pass (soleOwnerRefFreeRuns.ms).
//
// RED MEANS: the ref-free exemption widened past types with no ref.
//
// GUARD-CHECK-FAIL a sink parameter does not prove it is the only owner
// GUARD-CHECK-FAIL is not a fresh value

class Node { n: int32 = 0; }
struct Holder { node: Node; }

actor Store {
	putNode(n: Node): int32 { return n.n; }
	putNodes(ns: Vec<Node>): int32 { return ns.length as int32; }
	putHolder(h: Holder): int32 { return h.node.n; }
	putShared(s: Shared): int32 { return s.v; }
}

async function classParam(store: Store, sink n: Node): Promise<int32> {
	return await store.putNode(move n); // GUARD-REFUSED
}

async function vecOfClass(store: Store, sink ns: Vec<Node>): Promise<int32> {
	return await store.putNodes(move ns); // GUARD-REFUSED
}

async function structWithClass(store: Store, sink h: Holder): Promise<int32> {
	return await store.putHolder(move h); // GUARD-REFUSED
}

async function vecOfClassSpread(store: Store, sink ns: Vec<Node>): Promise<int32> {
	const fresh: Vec<Node> = [...ns];
	return await store.putNodes(move fresh); // GUARD-REFUSED
}

interface Shared { v: int32; }
async function interfaceParam(store: Store, sink s: Shared): Promise<int32> {
	return await store.putShared(move s); // GUARD-REFUSED
}
