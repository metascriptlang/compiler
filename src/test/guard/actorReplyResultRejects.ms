// An actor reply `Result.ok(state)` still refuses state the actor keeps
//
// INVARIANT (ULTRALOCK V0): wrapping a value in `Result.ok` does not make it fresh: a class or a
//   Vec field of the actor still reaches the caller through the Result.
//
// RED MEANS: the Result builders were exempted for their arguments too.
//
// GUARD-CHECK-FAIL the reply of 'field' may cross to the caller while the actor still reaches it
// GUARD-CHECK-FAIL the reply of 'cls' may cross to the caller while the actor still reaches it

class Node { n: int32 = 0; }

actor Holder {
	keys: Vec<uint8> = [1, 2];
	node: Node = new Node();

	field(): Result<Vec<uint8>, string> { return Result.ok(this.keys); } // GUARD-REFUSED
	cls(): Result<Node, string> { return Result.ok(this.node); } // GUARD-REFUSED
}
