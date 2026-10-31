// @stdout: A ext
// @stdout: B ext
// @stdout: sync 2
// @stdout: async 7
// @stdout: relay 14
// @exit: 0
// @xfail(raiser): raiser has no actors
// note: an extension on an actor is a free function on the caller's side: a sync one is typed as declared, an async one awaits the actor's messages, and the same name on two actors overloads by receiver (old compiler: the call was typed Promise by the checker and lowered as a direct call, so the C build failed)

actor A { n: int32 = 1; get(): int32 { return this.n; } }
actor B { n: int32 = 2; get(): int32 { return this.n; } }

function describe(this a: A): string { return "A ext"; }
function describe(this b: B): string { return "B ext"; }
function twice(this a: A): int32 { return 2; }
async function plus(this a: A, k: int32): Promise<int32> { return (await a.get()) + k; }

actor Relay {
	hop(a: A): int32 { return a.twice() + 12; }
}

const a = new A();
const b = new B();
console.log(a.describe());
console.log(b.describe());
console.log("sync " + a.twice());
console.log("async " + (await a.plus(6)));
console.log("relay " + (await new Relay().hop(a)));
