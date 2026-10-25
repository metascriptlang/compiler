// A closure sent without a reply carries only copies
//
// INVARIANT (ULTRALOCK V0, V4): a send has no reply, so nothing ends a loan it would start; a
//   Sendable closure sent fire-and-forget captures only copies, Arc<T> or Locked<T>, never a
//   reference the sender still holds and may write after the send.
//
// WHAT IT CATCHES: a borrowed capture written after the send, one sent to several actors, a
//   closure bound to a const first, a closure inside a moved object, a nested function
//   declaration, and a Sendable value whose captures the send cannot see.
//
// RED MEANS: one of the shapes compiled. Accepted neighbours: actorSendCopiesRun.ms.
//
// GUARD-JS
// GUARD-CHECK-FAIL a send without a reply runs this closure on the actor after this code moves on, so it cannot borrow 'b'
// GUARD-CHECK-FAIL a send without a reply runs 'g' on the actor after this code moves on

class Box { n: int32 = 0; }
interface Job { run: Sendable<() => int32>; }

actor W {
	total: int32 = 0;
	run(f: Sendable<() => int32>): void { this.total = this.total + f(); }
	job(j: Job): void { this.total = this.total + j.run(); }
}

function writeAfter(w: W): void {
	const b = new Box();
	b.n = 1;
	w.run(() => b.n); // GUARD-REFUSED
	b.n = 2;
}

function toMany(ws: W[]): void {
	const b = new Box();
	for (const w of ws) w.run(() => b.n); // GUARD-REFUSED
}

function bound(w: W): void {
	const b = new Box();
	const f = () => b.n;
	w.run(f); // GUARD-REFUSED
}

function inObject(w: W): void {
	const b = new Box();
	const j: Job = { run: () => b.n };
	w.job(move j); // GUARD-REFUSED
}

function nested(w: W): void {
	const b = new Box();
	function read(): int32 { return b.n; }
	w.run(read); // GUARD-REFUSED
}

function forward(w: W, g: Sendable<() => int32>): void {
	w.run(g); // GUARD-REFUSED
}

const w = new W();
writeAfter(w);
