// nim-guard: a spawn thunk inside an actor method may read the actor's fields (ULTRALOCK T6)
//
// INVARIANT: the neighbour of the alias refusals: reading 'this.n' in the thunk,
//   and capturing a primitive copied out of a field, compile and run.
// RED MEANS: the alias rule over-reaches into field reads.
//
// GUARD-JS

actor A {
	n: int32 = 3;
	m(): int32 {
		const k = this.n;
		return await spawn(() => this.n * 1000 + k);
	}
}

const a = new A();
const r = await a.m();
console.log(r == 3003 ? "GUARD-OK" : `GUARD-FAIL r=${r}`);
