// nim-guard: a spawn thunk cannot reach 'this' through a captured closure (ULTRALOCK T6)
//
// INVARIANT: the variant of actorSpawnSelfAliasRejects through a closure env: a
//   const closure that calls an actor method carries 'this' into the thunk.
// RED MEANS: the rule stops at the closure the thunk calls.
//
// GUARD-JS
// GUARD-CHECK-FAIL spawn thunk cannot use method 'other' of 'this'

actor A {
	n: int32 = 3;
	other(this: Readonly<A>): int32 { return this.n; }
	m(): int32 {
		const g = (): void => { this.other(); };
		return await spawn(() => { g(); return 0; });
	}
}

const a = new A();
console.log(`${await a.m()}`);
