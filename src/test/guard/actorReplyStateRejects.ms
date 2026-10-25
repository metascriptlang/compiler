// An actor's reply never carries a reference the actor still reaches
//
// INVARIANT (ULTRALOCK V0, V2): a reply crosses to the caller's thread, so it is a COPY, a fresh
//   value nothing in the actor keeps, or an Arc<T>; a field path of 'this' is none of them.
//
// WHAT IT CATCHES: a reply of the actor's own state: a class field, a nullable class field, an
//   array field, a local alias of a field, a fallback between two of its fields, a fresh local the
//   actor also stored, and a generic method whose replies no per-type check reaches. The caller
//   would then write what the actor reads, from another thread.
//
// RED MEANS: one of the shapes compiled. Accepted neighbours: actorReplyCopiesRun.ms.
//
// GUARD-JS
// GUARD-CHECK-FAIL the reply of 'root' may cross to the caller while the actor still reaches it — it replies with 'this.top', which stays in the actor; reply with a copy
// GUARD-CHECK-FAIL the reply of 'maybe' may cross to the caller while the actor still reaches it — it replies with 'this.last'
// GUARD-CHECK-FAIL the reply of 'all' may cross to the caller while the actor still reaches it — it replies with 'this.hits'
// GUARD-CHECK-FAIL the reply of 'pick' may cross to the caller while the actor still reaches it — it replies with a value
// GUARD-CHECK-FAIL the reply of 'alias' may cross to the caller while the actor still reaches it — 'r' is not the sole owner
// GUARD-CHECK-FAIL the reply of 'kept' may cross to the caller while the actor still reaches it — 'n' is not the sole owner
// GUARD-CHECK-FAIL actor method 'echo' is generic, so the reply of each instance cannot be checked before it crosses to the caller

import { stop, ExitReason } from "std/actor";

class Node { hits: int32 = 0; next: Node | null = null; }

actor Scene {
	top: Node = new Node();
	last: Node | null = null;
	hits: int32[] = [];
	root(): Node { return this.top; } // GUARD-REFUSED
	maybe(): Node | null { return this.last; } // GUARD-REFUSED
	all(): int32[] { return this.hits; } // GUARD-REFUSED
	pick(): Node { return this.top.next ?? this.top; } // GUARD-REFUSED
	alias(): Node {
		const r = this.top;
		return r; // GUARD-REFUSED
	}
	echo<T>(x: T): T { return x; } // GUARD-REFUSED
	kept(): Node {
		const n = new Node();
		this.last = n;
		return n; // GUARD-REFUSED
	}
}

const s = new Scene();
console.log((await s.root()).hits);
stop(s.pid, ExitReason.Normal);
