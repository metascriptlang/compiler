// nim-guard: a spawn thunk cannot call the actor's methods through an alias (ULTRALOCK T6)
//
// INVARIANT: the variant of actorSpawnSelfAliasRejects on the use: calling a
//   method through the alias, which E61 refuses when it is spelled 'this.other()'.
// RED MEANS: method calls through an alias reach the suspended actor.
//
// GUARD-JS
// GUARD-CHECK-FAIL cannot capture 'self', which can hold the actor 'this'

actor A {
	n: int32 = 3;
	other(this: Readonly<A>): int32 { return this.n; }
	m(): int32 {
		const self = this;
		return await spawn(() => { self.other(); return 0; });
	}
}

const a = new A();
console.log(`${await a.m()}`);
