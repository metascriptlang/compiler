// @stdout: true true true true
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: an actor turns into text as its handle alone, from outside and from inside its own methods: its state belongs to the actor's thread, so neither String() nor a template reads it.

actor Counter {
	n: int32 = 0;
	inc(): void { this.n += 1; }
	show(): string { return String(this); }
}

function handleOnly(s: string): boolean { return s.startsWith("{\"pid\":") && s.indexOf("\"n\"") < 0; }

const c = new Counter();
c.inc();
const inside = await c.show();
console.log(handleOnly(String(c)), handleOnly(`${c}`), handleOnly(inside), String(c) == inside);
