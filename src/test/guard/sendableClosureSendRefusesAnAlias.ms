// nim-guard: a Sendable closure sent to an actor without a reply is handed over like a `move`,
//   so the binding that holds it must be its sole owner.
//
// INVARIANT (ULTRALOCK V2, V3, M1): after the send the sender keeps no count on the closure's env.
//   An alias, a stored copy or a capture by another closure made before the send would keep
//   counting that env on the sender's thread with plain rc while the actor counts it on its own.
//
// WHAT IT CATCHES: the state measured 2026-11-14 on bac1b95e1948, where the alias, the stored
//   copy and the capturing closure each passed `msc check` and only a use of the sent name was
//   refused.
//
// RED MEANS: a second holder of a sent closure compiles again.
//
// GUARD-CHECK-FAIL it is bound to 'g'
// GUARD-CHECK-FAIL it is stored in an array literal
// GUARD-CHECK-FAIL a closure captures it
// GUARD-CHECK-FAIL was moved into a spawn thunk or an actor call

actor Sink {
	total: int32 = 0;
	take(f: Sendable<() => int32>): void { this.total += f(); }
}

function aliasKept(a: Readonly<Sink>, n: int32): int32 {
	const f: Sendable<() => int32> = () => n;
	const g = f;
	a.take(f); // GUARD-REFUSED
	return g();
}

function storedThenSent(a: Readonly<Sink>, n: int32): int32 {
	const f: Sendable<() => int32> = () => n;
	const keep: Sendable<() => int32>[] = [f];
	a.take(f); // GUARD-REFUSED
	return keep[0]();
}

function capturedThenSent(a: Readonly<Sink>, n: int32): int32 {
	const f: Sendable<() => int32> = () => n;
	const again = (): int32 => f();
	a.take(f); // GUARD-REFUSED
	return again();
}

function usedAfter(a: Readonly<Sink>, n: int32): int32 {
	const f: Sendable<() => int32> = () => n;
	a.take(f);
	return f(); // GUARD-REFUSED
}

const sink = new Sink();
console.log(aliasKept(sink, 1) + storedThenSent(sink, 2) + capturedThenSent(sink, 3) + usedAfter(sink, 4));
