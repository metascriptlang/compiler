// nim-guard: an Isolated<T> has no copy.
//
// INVARIANT (the reference's `=copy` {.error.}): std/isolation declares onDestroy and no
//   onCopy for Isolated<T>, so a copy that cannot become the last use of a binding is an
//   error that names the type, and a borrowed parameter cannot be moved on because the
//   move would be a copy.
//
// WHAT IT CATCHES: Isolated<T> gaining a copy, which would let two bindings reach one graph
//   and defeat the sole-owner proof that `move iso` of a `sink` parameter relies on.
//
// RED MEANS: the analyzer's unavailable-copy report (analyzer/inject.ms reportUnavailableCopy)
//   stopped covering Isolated<T>, or the type declares onCopy.
//
// GUARD-CHECK-FAIL cannot copy 'iso'
// GUARD-CHECK-FAIL cannot copy 'borrowed'
// GUARD-CHECK-FAIL 'Isolated<Req>' declares onDestroy and no onCopy

import { Isolated } from "std/isolation";

class Node { n: int32 = 0; }
struct Req { name: string; node: Node; }

function use(r: Isolated<Req>): int32 { return r.value.node.n; }

// 1 — a copy of a binding that is read again afterwards.
function copyThenRead(sink iso: Isolated<Req>): int32 {
	const b = iso; // GUARD-REFUSED
	return use(iso) + use(b);
}

// 2 — a borrowed parameter cannot be moved on: that is a copy of what the caller owns.
function moveBorrowed(borrowed: Isolated<Req>): int32 {
	const b = move borrowed; // GUARD-REFUSED
	return use(b);
}
