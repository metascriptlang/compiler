// @xfail(raiser): the Raiser VM has no actors
// @skip-js: Arc<T> is a C-backend atomic-rc box; no js binding
// @maxrss: 20
// @stdout: undelivered stopped=400 reaped=400 queued=400 call=400
// @serial
// note: a message its actor never runs (sent after a stop, to a reaped pid, or left in the
// mailbox when the actor stops, or a CALL to a stopped actor) returns the Arc reference the send took and frees the string
// copy it carries (ULTRALOCK M7). Each message holds a ~16 KB Arc payload and a ~16 KB string,
// so the old compiler, which released neither, peaked at 48 MB here against 10 MB fixed (c lane, Linux); flat RSS is the oracle.
// The moved-graph argument of the same paths is pinned by actorDropReleasesUndeliveredArgs.
import { stop, ExitReason } from "std/actor";
import { sleepAsync } from "std/core/promise";

struct Payload { buf: string; n: int32; }

actor Sink {
	total: int32 = 0;
	absorb(p: Arc<Payload>, s: string): void { this.total = this.total + p.n + s.length; }
	weigh(p: Arc<Payload>, s: string): int32 { return p.n + s.length; }
	park(): void { const r = await spawn(() => 1); this.total = this.total + r; }
}

const big = "x".repeat(16384);

function payload(i: int32): Arc<Payload> {
	return new Arc({ buf: `${big}${i}`, n: 7 });
}

async function main(): Promise<void> {
	let stopped = 0;
	for (let i = 0; i < 400; i += 1) {
		const s = new Sink();
		stop(s.pid, ExitReason.Normal);
		s.absorb(payload(i), `${big}${i}`);
		stopped += 1;
	}

	const gone: Sink[] = [];
	for (let i = 0; i < 400; i += 1) {
		const s = new Sink();
		stop(s.pid, ExitReason.Normal);
		gone.push(s);
	}
	await sleepAsync(20);
	let reaped = 0;
	for (const s of gone) {
		s.absorb(payload(reaped), `${big}${reaped}`);
		reaped += 1;
	}

	let queued = 0;
	for (let i = 0; i < 400; i += 1) {
		const s = new Sink();
		s.park();
		s.absorb(payload(i), `${big}${i}`);
		stop(s.pid, ExitReason.Normal);
		queued += 1;
	}

	let call = 0;
	for (let i = 0; i < 400; i += 1) {
		const s = new Sink();
		stop(s.pid, ExitReason.Normal);
		const k = try await s.weigh(payload(i), `${big}${i}`) catch -1;
		if (k < 0) call += 1;
	}
	await sleepAsync(20);
	console.log(`undelivered stopped=${stopped} reaped=${reaped} queued=${queued} call=${call}`);
}

await main();
