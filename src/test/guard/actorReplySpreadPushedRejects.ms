// A pushed value that keeps a ref the actor holds stays refused in a reply
//
// INVARIANT (ULTRALOCK V0): the spread of scalars is a copy, but a class the actor keeps, pushed
//   beside it, or a spread of refs, still reaches the actor's state from the reply.
//
// RED MEANS: the spread exemption in isFreshValue covers more than ref-free elements.
//
// GUARD-CHECK-FAIL the reply of 'sharedNode' may cross to the caller while the actor still reaches it
// GUARD-CHECK-FAIL the reply of 'spreadNodes' may cross to the caller while the actor still reaches it

class Node { n: int32 = 0; }
struct Entry { node: Node; key: Vec<uint8>; }

actor Holder {
	keys: Vec<uint8> = [1, 2];
	node: Node = new Node();
	nodes: Vec<Node> = [];

	sharedNode(): Entry[] {
		let out: Entry[] = [];
		out.push({ node: this.node, key: [...this.keys] });
		return out; // GUARD-REFUSED
	}
	spreadNodes(): Vec<Node>[] {
		let out: Vec<Node>[] = [];
		out.push([...this.nodes]);
		return out; // GUARD-REFUSED
	}
}
