// PARALOCK scenario — actor only.
//
// Covers: SEND (void method) + CALL (returning method) with int and
// heap-string args. The string path exercises COPY semantics for
// value-typed msString via the actor mailbox (regression for the
// multi-WS broadcast string-corruption bug). PARALOCK §7.6.

actor Counter {
	n: number = 0;
	tag: string = "";

	bump(amount: number): void {
		this.n = this.n + amount;
	}

	setTag(s: string): void {
		this.tag = s;
	}

	get(): number {
		return this.n;
	}

	getTag(): string {
		return this.tag;
	}
}

function makeHeapStr(): string {
	let s = "topic-";
	s = s + "room";
	return s;
}

function main(): void {
	const c = new Counter();
	c.bump(5);
	c.bump(7);
	c.setTag(makeHeapStr());

	const n = await c.get();
	if (n !== 12) { console.log("FAIL n=" + n); return; }

	const t = await c.getTag();
	if (t !== "topic-room") { console.log("FAIL tag=[" + t + "]"); return; }

	console.log("PASS: actorOnly");
}

main();
