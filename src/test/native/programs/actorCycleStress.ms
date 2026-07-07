// Actor scheduler stress for the strand fix (Amendment C): cycle-detector reaping +
// cross-thread wasEmpty sends from multiple producers + actor create/destroy churn.
// Exercises the deschedule paths the fix rewrote — markEmpty-as-last-consumer-op under
// processing, the deferred re-enqueue, the re-push-on-processing-CAS-fail, and the
// BLOCKED/RC cycle-detector hand-off (system messages flow through the same deschedule
// path). The high-level Supervisor / link / monitor surface is not wired yet, so this
// drives the SAME underlying CD + destroy + multi-producer-send paths with primitives.
// A strand regression hangs (CALL future never completes); a scheduler race trips TSan.

actor Counter {
	n: number = 0;
	add(x: number): void { this.n = this.n + x; }
	get(): number { return this.n; }
}

function bump(c: Counter, k: number): number {
	c.add(k);   // actor SEND from a pool worker thread — cross-thread wasEmpty push
	return k;
}

function churn(): number {
	const c = new Counter();                  // fresh actor, RC>0 while captured → CD-tracked
	const h1 = spawn(() => bump(c, 1));        // worker thread sends to the actor
	const h2 = spawn(() => bump(c, 2));        // a second concurrent producer
	const r1 = await h1;
	const r2 = await h2;
	c.add(3);                                  // main-thread SEND (third producer)
	const v = await c.get();                   // CALL — must see all three adds
	return v;                                  // c drops → RC→0 → reaped
}

function main(): void {
	let acc = 0;
	for (let i = 0; i < 200000; i = i + 1) {
		const v = churn();
		if (v !== 6) { console.log(`FAIL iter=${i} v=${v}`); return; }
		acc = (acc + v) % 1000;
	}
	console.log(`actor-cycle-stress done acc=${acc}`);
}
main();
