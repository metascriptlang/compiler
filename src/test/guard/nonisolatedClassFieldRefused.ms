// A nonisolated field of a reference type would be read as a shared object by other threads.
// A guard that compiles clean means a class-typed field was accepted again.
//
// GUARD-CHECK-FAIL a nonisolated field is read from other threads, so it must be readonly and of a value type (number, bigint, boolean, string, enum)

import { nonisolated } from "std/actor";

class Box {
	n: int32 = 1;
}

actor Srv {
	@nonisolated
	readonly box: Box = new Box();
	inside(): int32 { return this.box.n; }
}

const s = new Srv();
console.log(s.pid);
