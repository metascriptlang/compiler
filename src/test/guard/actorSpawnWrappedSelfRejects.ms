// nim-guard: a value that holds 'this' cannot be captured by a spawn thunk (ULTRALOCK T6)
//
// INVARIANT: the variant of actorSpawnSelfAliasRejects one level deeper: the
//   actor sits inside an object, and the object is captured.
// RED MEANS: only a binding whose own type is the actor is judged.
//
// GUARD-JS
// GUARD-CHECK-FAIL cannot capture 'box', which can hold the actor 'this'

class Box { a: A; constructor(a: A) { this.a = a; } }

actor A {
	n: int32 = 3;
	m(): int32 {
		const box = new Box(this);
		return await spawn(() => { console.log(box); return 0; });
	}
}

const a = new A();
console.log(`${await a.m()}`);
