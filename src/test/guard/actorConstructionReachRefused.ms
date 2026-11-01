// INVARIANT: ULTRALOCK V0, M1, A4 (what an actor builds at construction runs on its thread).
// RED MEANS: a closure the actor stores, or a constructor run on another thread, reaches module state unchecked.
// GUARD-JS
// GUARD-CHECK-FAIL runs the closure stored in
// GUARD-CHECK-FAIL constructs the actor 'Writes'
// GUARD-CHECK-FAIL module state crosses threads only as a const value

let hits: int32 = 0;

actor Stored {
	cb: () => void;
	constructor() {
		this.cb = (): void => { hits = hits + 1; }; // GUARD-REFUSED
	}
	go(): int32 { this.cb(); return 1; }
}

actor Initialized {
	inc: () => void = (): void => { hits = hits + 1; }; // GUARD-REFUSED
	go(): int32 { this.inc(); return 1; }
}

actor Writes {
	constructor() { hits = hits + 1; }
	ping(): int32 { return 1; }
}

actor Builder {
	make(): int32 { const w = new Writes(); return 1; } // GUARD-REFUSED
}

const t = spawn((): int32 => { const w = new Writes(); return 1; }); // GUARD-REFUSED
const s = new Stored();
const i = new Initialized();
const b = new Builder();
console.log(`${await t} ${await s.go()} ${await i.go()} ${await b.make()} ${hits}`);
