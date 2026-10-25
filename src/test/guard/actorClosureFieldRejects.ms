// A plain closure never reaches an actor inside another value
//
// INVARIANT (ULTRALOCK V0): a value keeps its region through a closure env, so a plain function
//   that crosses to an actor inside an object, a nested object or an array is refused like a bare
//   one; it may capture module state and would run on the actor's thread.
//
// WHAT IT CATCHES: a closure in a field, one level deeper, and in an array element, on an awaited
//   CALL and on a send.
//
// RED MEANS: one of the shapes compiled. An object with only scalar fields still crosses
//   (actorSendCopiesRun.ms).
//
// GUARD-JS
// GUARD-CHECK-FAIL c.f is a plain function inside a value that crosses to the actor
// GUARD-CHECK-FAIL o.inner.f is a plain function inside a value that crosses to the actor
// GUARD-CHECK-FAIL fs[] is a plain function inside a value that crosses to the actor

import { stop, ExitReason } from "std/actor";

interface Cb { f: () => int32; }
interface Outer { inner: Cb; }

actor Reader {
	call(c: Cb): int32 { return c.f(); }
	deep(o: Outer): int32 { return o.inner.f(); }
	each(fs: (() => int32)[]): int32 { return fs[0](); }
	post(c: Cb): void { c.f(); }
}

let counter: int32 = 0;
const r = new Reader();
const c: Cb = { f: () => { counter = counter + 1; return counter; } };
const o: Outer = { inner: c };
const fs = [() => { counter = counter + 1; return counter; }];
console.log(await r.call(c)); // GUARD-REFUSED
console.log(await r.deep(o)); // GUARD-REFUSED
console.log(await r.each(fs)); // GUARD-REFUSED
const sent: Cb = { f: () => { counter = counter + 1; return counter; } };
r.post(move sent); // GUARD-REFUSED
stop(r.pid, ExitReason.Normal);
