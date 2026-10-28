// @stdout: B.back begin
// @exit: 13
// @skip-js: Node exits 13 here too, but its warning names the emitted .js file and quotes its source, so the output cannot be byte-compared with the native lanes
// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// note: A awaits B, and B awaits a call back into A, which stays frozen until its own method returns (ULTRALOCK A2). Nothing can settle either reply, so the program ends with exit 13 instead of hanging.

actor A {
	m(b: B): int32 { return await b.back(this); }
	ping(): int32 { return 1; }
}

actor B {
	back(a: A): int32 {
		console.log("B.back begin");
		return await a.ping();
	}
}

const a = new A();
const b = new B();
console.log(`${await a.m(b)}`);
