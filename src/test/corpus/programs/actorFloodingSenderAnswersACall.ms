// @serial
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: took 600000
// @ledger-slack(Sink) 10
// @ledger-slack(Src) 10
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: the awaited-reply variant of actorFloodingSenderKeepsRunning: the flooding actor
//   answers an awaited CALL after its burst. It hung 3 runs of 10 while senders could be
//   paused.

actor Sink {
	n: int32 = 0;
	take(v: int32): void {
		let s = 0;
		for (let i = 0; i < 300; i = i + 1) { s = s + (i % 7); }
		this.n = this.n + v;
	}
	get(): int32 {
		return this.n;
	}
}

actor Src {
	fired: int32 = 0;
	sink: Sink | null = null;
	attach(s: Sink): void {
		this.sink = s;
	}
	fire(): void {
		const s = this.sink;
		if (s == null) return;
		for (let i = 0; i < 200; i = i + 1) {
			s.take(1);
		}
		this.fired = this.fired + 1;
	}
	total(): int32 {
		const s = this.sink;
		if (s == null) return -1;
		return await s.get();
	}
}

let took = 0;
for (let r = 0; r < 10; r = r + 1) {
	const sink = await spawn(() => new Sink());
	const src = new Src();
	src.attach(move sink);
	for (let k = 0; k < 300; k = k + 1) {
		src.fire();
	}
	took = took + (await src.total());
}
console.log("took " + took.toString());
