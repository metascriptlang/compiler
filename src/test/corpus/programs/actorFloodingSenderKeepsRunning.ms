// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms)
// @serial
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: rounds 20
// note: an actor that floods a busy receiver and then waits on a reply from it keeps
//   being scheduled. The runtime once paused a sender whose receiver was behind and
//   dropped the paused actor's run-queue entry; this shape then hung 10 runs of 10.

actor B {
	back: A | null = null;
	setBack(a: A): int32 {
		this.back = a;
		return 0;
	}
	take(v: int32): void {
		let s = 0;
		for (let i = 0; i < 2000; i = i + 1) { s = s + (i % 7); }
	}
	ask(): int32 {
		const a = this.back;
		if (a == null) return -1;
		return pingSync(a);
	}
}

actor A {
	sink: B | null = null;
	attach(b: B): void {
		this.sink = b;
	}
	fire(): void {
		const s = this.sink;
		if (s == null) return;
		for (let i = 0; i < 200; i = i + 1) { s.take(1); }
		s.ask();
	}
	ping(): int32 {
		return 1;
	}
}

function pingSync(a: A): int32 {
	return await a.ping();
}

function round(): int32 {
	const a = new A();
	const b = await spawn(() => new B());
	await b.setBack(a);
	a.attach(move b);
	for (let k = 0; k < 50; k = k + 1) { a.fire(); }
	return await a.ping();
}

function main(): void {
	let total = 0;
	for (let r = 0; r < 20; r = r + 1) {
		total = total + round();
	}
	console.log(`rounds ${total}`);
}
main();
