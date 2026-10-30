// An actor constructor argument crosses to the actor like a method argument
//
// INVARIANT (ULTRALOCK V0): a constructor argument the actor keeps is reachable from its thread,
//   so it passes the same send check as a fire-and-forget method argument: a plain function inside
//   it, or a plain reference the creator keeps, is refused.
//
// WHAT IT CATCHES: a closure in a struct field and a shared class reference, both through `new`.
//
// RED MEANS: one of the shapes compiled, and the creator and the actor would count one closure env
//   or object from two threads. A moved reference and a scalar still cross.
//
// GUARD-JS
// GUARD-CHECK-FAIL info.call is a plain function inside a value that crosses to the actor
// GUARD-CHECK-FAIL fire-and-forget actor call would share a plain reference across threads

import { stop, ExitReason } from "std/actor";

class Guest { n: int64 = 0; }
struct Info { call: (x: int64) => int64; }

actor Exec {
	info: Info;
	constructor(info: Info) { this.info = info; }
}

actor Keeper {
	guest: Guest;
	constructor(guest: Guest) { this.guest = guest; }
}

actor Counter {
	n: int64;
	constructor(n: int64) { this.n = n; }
}

const guest = new Guest();
const info: Info = { call: (x: int64): int64 => { guest.n += x; return guest.n; } };
const e = new Exec(info); // GUARD-REFUSED
const k = new Keeper(guest); // GUARD-REFUSED
function keepOwned(): Keeper {
	const owned = new Guest();
	return new Keeper(move owned);
}
const m = keepOwned();
const c = new Counter(3);
stop(e.pid, ExitReason.Normal);
stop(k.pid, ExitReason.Normal);
stop(m.pid, ExitReason.Normal);
stop(c.pid, ExitReason.Normal);
