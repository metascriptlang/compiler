// nim-guard: an alias of 'this' cannot be captured by a spawn thunk (ULTRALOCK T6)
//
// INVARIANT: a spawn thunk inside an actor method does not capture 'this' as a
//   whole, and a binding that holds the actor is 'this' under another name.
// RED MEANS: the rule only matches the spelling 'this'; `const self = this`
//   hands the suspended actor to another thread.
//
// GUARD-JS
// GUARD-CHECK-FAIL cannot capture 'self', which can hold the actor 'this'

actor A {
	n: int32 = 3;
	m(): int32 {
		const self = this;
		return await spawn(() => { console.log(self); return 0; });
	}
}

const a = new A();
console.log(`${await a.m()}`);
