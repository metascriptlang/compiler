// @maxrss: 80
// @stdout: paralock-nested check=
// @serial
// note: PARALOCK guard: spawn + actor + async crossed, 20k-iteration massive interleave on the shared worker pool. Standing answer to 'did my change break PARALOCK seamlessly?'. The final marker only prints if the actor tag round-trips. Higher RSS bound — concurrency runtime has a larger steady-state baseline (pool threads + mailboxes).

// PARALOCK guard — spawn + actor + async crossed, massive, run NATIVELY.
//
// docs/PARALOCK.md locks the unified model: spawn (parallel tasks), actor
// (isolated state), await (one keyword). They interleave on ONE shared worker
// pool.
//
// This runs all three crossed in a massive loop on the real native runtime,
// under both --gc=drc and --gc=orc, asserting: correct results (exit 0) AND
// flat RSS (no per-iteration leak as futures/messages/closures churn). It is
// the standing answer to "did my change break PARALOCK seamlessly?".
//
// Only SHIPPED combos are used (spawn fan-out + await, actor SEND/CALL + await,
// async chain + await, all interleaved). Spawn-inside-actor (S1/S3 static rules
// still pending per PARALOCK §6) is intentionally excluded.

actor Accumulator {
	total: number = 0;
	tag: string = "";

	add(amount: number): void { this.total = this.total + amount; }
	setTag(s: string): void { this.tag = s; }
	get(): number { return this.total; }
	getTag(): string { return this.tag; }
}

function square(x: number): number { return x * x; }

async function asyncDouble(x: int32): Promise<int32> { return (x * 2) as int32; }

async function asyncStep(x: int32): Promise<int32> {
	const d = await asyncDouble(x);
	return (d + 1) as int32;
}

function main(): void {
	const acc = new Accumulator();
	acc.setTag("paralock-room");
	let check = 0;

	for (let iter = 0; iter < 20000; iter = iter + 1) {
		// A spawn thunk borrows the enclosing env, so it may only capture const
		// bindings — snapshot the loop counter before fanning out.
		const it = iter;
		// spawn fan-out — parallel compute, awaited as a group
		const h1 = spawn(() => square(it % 7));
		const h2 = spawn(() => square((it + 1) % 7));
		const r1 = await h1;
		const r2 = await h2;

		// actor SEND (mutate) + CALL (read), awaited — crosses into actor lane
		acc.add((r1 + r2) % 5);
		const live = await acc.get();

		// async chain — cooperative yield lane
		const s = await asyncStep((iter % 11) as int32);

		check = ((check + (live % 3) + (s as number)) % 100000) as int32;
	}

	const tag = await acc.getTag();
	if (tag !== "paralock-room") { console.log(`FAIL tag=[${tag}]`); return; }
	console.log(`paralock-nested check=${check} total=${await acc.get()}`);
}

main();
