// INVARIANT: ULTRALOCK V0 and M1 (an actor's visits run on any pool thread).
// RED MEANS: an actor method reaching module state compiles again.
// GUARD-JS
// GUARD-CHECK-FAIL on whichever thread takes its message
// GUARD-CHECK-FAIL module state crosses threads only as a const value

let hits: int32 = 0;
let limit: int32 = 1;

function bump(): void {
	hits = hits + 1;
}

actor Writer {
	write(): void { hits = hits + 1; } // GUARD-REFUSED
}

actor Reader {
	read(): int32 { return limit; } // GUARD-REFUSED
}

actor Caller {
	tick(): void { bump(); } // GUARD-REFUSED
}

actor Idler {
	onIdle(): void { hits = hits + 1; } // GUARD-REFUSED
	ping(): int32 { return 1; }
}

class Reg {
	static n: int32 = 0;
}

actor StaticWriter {
	bump(): void { Reg.n = Reg.n + 1; } // GUARD-REFUSED
}

let target = new Idler();

actor Messenger {
	poke(): void { target.ping(); } // GUARD-REFUSED
}

class Cell {
	n: int32 = 1;
}

let loose = new Cell();

class Boxed {
	static readonly box: Readonly<Cell> = new Cell();
	static { Boxed.box = loose; }
}

actor BoxReader {
	read(): int32 { return Boxed.box.n; } // GUARD-REFUSED
}

limit = 5;
target = new Idler();
const w = new Writer();
const r = new Reader();
const c = new Caller();
const i = new Idler();
const s = new StaticWriter();
const m = new Messenger();
w.write();
c.tick();
s.bump();
m.poke();
console.log(`${await r.read()} ${await i.ping()} ${hits}`);
console.log("GUARD-OK");
