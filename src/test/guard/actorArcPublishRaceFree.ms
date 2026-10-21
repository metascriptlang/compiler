// nim-guard: an Arc payload sent to actors and a spawned future are counted before they publish
//
// INVARIANT (ULTRALOCK M7): a value another thread can reach is kept alive by a count taken
//   before it becomes visible there: the Arc argument at the message setter, the reply future
//   before the mailbox push, the spawned future before the pool submit.
//
// WHAT IT CATCHES: a count taken after the publish, or a plain (non-atomic) count on a cell two
//   threads touch; TSan reports the race and ASan-side lanes see the early free.
//
// RED MEANS: a publication site moved its count after the publish or stopped counting atomically.
//
// GUARD-TSAN

struct Payload { n: int32; }

actor Sink {
	total: int32 = 0;
	absorb(p: Arc<Payload>): void { this.total = this.total + p.n; }
	weigh(p: Arc<Payload>): int32 { return p.n + this.total - this.total; }
}

function work(k: int32): int32 { return k + 1; }

async function round(sinks: Sink[], i: int32): Promise<int32> {
	const a: Arc<Payload> = new Arc({ n: i });
	for (const s of sinks) s.absorb(a);
	let sum: int32 = 0;
	for (const s of sinks) sum += await s.weigh(a);
	const both = await Promise.all([spawn(() => work(i)), spawn(() => work(1))]);
	return sum + both[0] + both[1];
}

async function main(): Promise<void> {
	const sinks: Sink[] = [new Sink(), new Sink(), new Sink(), new Sink()];
	let total: int32 = 0;
	for (let i: int32 = 0; i < 200; i += 1) total += await round(sinks, i);
	if (total != 100100) { throw "GUARD RED: total=" + total; }
	console.log("GUARD-OK");
}

main();
