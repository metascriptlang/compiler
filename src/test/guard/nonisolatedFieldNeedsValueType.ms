// A nonisolated field is read from other threads while the actor runs and tears down, so its
// declaration is gated: readonly, and a value type whose copy is independent.
// A guard that compiles clean means a mutable field was accepted again.
//
// GUARD-CHECK-FAIL a nonisolated field is read from other threads, so it must be readonly and of a value type (number, bigint, boolean, string, enum)

import { nonisolated } from "std/actor";

actor Srv {
	@nonisolated
	name: string = "srv";
	inside(): string { return this.name; }
}

const s = new Srv();
console.log(s.name);
