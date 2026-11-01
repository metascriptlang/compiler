// INVARIANT: ULTRALOCK V0 and A6 (a const of actors is shared only once its slot is written).
// RED MEANS: a const of actors whose initializer runs code that messages it is shared across threads.
// GUARD-JS
// GUARD-CHECK-FAIL module state crosses threads only as a const value

actor Counter {
	n: int32 = 0;
	add(k: int32): void { this.n += k; }
	read(): int32 { return this.n; }
}

actor Peer {
	constructor() { early[0].add(1); }
	ping(): int32 { return 1; }
}

function build(): Counter[] {
	const p = new Peer();
	const out: Counter[] = [new Counter()];
	return out;
}

const early: Readonly<Counter[]> = build();

actor Ticking {
	n: int32 = 0;
	constructor() { setTimeout((): void => { ticking.add(1); }, 0); }
	add(k: int32): void { this.n += k; }
	read(): int32 { return this.n; }
}

const ticking = new Ticking();

actor Relay {
	poke(): void { early[0].add(2); } // GUARD-REFUSED
	tick(): void { ticking.add(2); } // GUARD-REFUSED
}

const relay = new Relay();
await relay.poke();
await relay.tick();
console.log(`${await early[0].read()} ${await ticking.read()}`);
