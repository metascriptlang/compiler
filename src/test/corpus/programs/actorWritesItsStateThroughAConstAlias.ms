// @stdout: 8 9 10 11 hi!
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: a const bound to this, directly or through another such const, is the actor's own state: writes through it land, on every backend.

import { stop, ExitReason } from "std/actor";

actor Counter {
	n: int32 = 7;
	s: string = "hi";
	direct(): int32 { const me = this; me.n = me.n + 1; return this.n; }
	chained(): int32 { const self = this; const again = self; again.n = self.n + 1; return this.n; }
	inClosure(): int32 { const me = this; const bump = (): void => { me.n = me.n + 1; }; bump(); return this.n; }
	nested(): int32 { const me = this; if (me.n > 0) { const inner = me; inner.n = inner.n + 1; } return this.n; }
	text(): string { const me = this; me.s = me.s + "!"; return this.s; }
}

const c = new Counter();
const a = await c.direct();
const b = await c.chained();
const d = await c.inClosure();
const e = await c.nested();
console.log(a, b, d, e, await c.text());
stop(c.pid, ExitReason.Normal);
