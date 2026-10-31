// An overloaded actor method refuses the same arguments as a plain one
//
// INVARIANT (ULTRALOCK V0, V6): every value crossing into an actor is classified before the call
//   runs, whichever overload the call picks; an overload set is no way around the crossing check.
//
// WHAT IT CATCHES: a `let`-bound plain reference given to an awaited call, and a borrowing closure
//   given to a send, both on an actor method with overload signatures.
//
// RED MEANS: an overloaded call compiled with an argument the plain method refuses. Accepted
//   neighbour: the scalar and string calls below.
//
// GUARD-JS
// GUARD-CHECK-FAIL actor methods only accept value types, `move`, or `const` references
// GUARD-CHECK-FAIL a send without a reply runs this closure on the actor after this code moves on, so it cannot borrow 'b'

import { stop, ExitReason } from "std/actor";

interface Plain { n: int32; }
class Box { n: int32 = 0; }

actor Verbs {
	total: int32 = 0;
	weigh(p: Plain): int32;
	weigh(p: string): int32;
	weigh(p: Plain | string): int32 { return typeof p == "string" ? p.length : p.n; }
	run(f: Sendable<() => int32>): void;
	run(f: string): void;
	run(f: Sendable<() => int32> | string): void { this.total = this.total + (typeof f == "string" ? f.length : f()); }
}

async function refused(v: Verbs): Promise<int32> {
	let p: Plain = { n: 2 };
	return await v.weigh(p); // GUARD-REFUSED
}

function sendRefused(v: Verbs): void {
	const b = new Box();
	b.n = 1;
	v.run(() => b.n); // GUARD-REFUSED
	b.n = 2;
}

async function accepted(v: Verbs): Promise<int32> {
	const a = await v.weigh("abc");
	v.run("ab");
	return a;
}

const v = new Verbs();
console.log(await accepted(v), await refused(v));
sendRefused(v);
stop(v.pid, ExitReason.Normal);
