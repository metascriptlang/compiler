// Parity program — a generic class whose members never mention its type
// parameter in a field is still an open template: a constructor or method body
// holding a generic struct with a managed member requests no hooks for it.
//
// @stdout: ctor|none|two
// @exit: 0

struct Failure<E> { error: E; exception: Error | null; }

class State<E> {
	constructor() { const x: Failure<E> | null = null; }
}

class Probe<A, B> {
	look(): string {
		const p: Failure<A> | null = null;
		const q: Failure<B> | null = null;
		return p == null && q == null ? "none" : "some";
	}
}

const s = new State<int32>();
const p = new Probe<int32, string>();
const out: string[] = ["ctor", p.look()];
out.push(s == null ? "gone" : "two");
console.log(out.join("|"));
