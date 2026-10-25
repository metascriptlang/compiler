// @xfail(raiser): the Raiser VM has no actors and runs no user lifecycle hooks
// @skip-js: onDestroy runs where the DRC runs; JS has no destructors
// @stdout: stopped cargo=300
// @stdout: reaped cargo=300
// @stdout: queued cargo=300
// @serial
// note: a message its actor never runs (sent after a stop, to a reaped pid, or left in the
// mailbox when the actor stops) releases the graph moved into it, the way the method would
// have (old compiler: cargo=0, one graph leaked per message; ULTRALOCK M7). The Arc and
// string arguments of the same messages are pinned by actorDropReleasesUndeliveredArcAndString.
import { stop, ExitReason } from "std/actor";
import { sleepAsync } from "std/core/promise";

class Cargo { n: int32 = 0; next: Cargo | null = null; }

let cargoGone = 0;
function onDestroy(this c: Cargo): void { cargoGone += 1; }

actor Sink {
	total: int32 = 0;
	take(c: Cargo): void { this.total = this.total + c.n; }
	note(s: string): void { this.total = this.total + s.length; }
	park(): void { const r = await spawn(() => 1); this.total = this.total + r; }
}

function cargo(): Cargo {
	const c = new Cargo();
	const d = new Cargo();
	c.next = d;
	return c;
}

async function settle(graphs: int32): Promise<void> {
	for (let i = 0; i < 2000 && cargoGone < graphs; i += 1) await sleepAsync(1);
}

async function main(): Promise<void> {
	let c0 = cargoGone;
	for (let i = 0; i < 300; i += 1) {
		const s = new Sink();
		stop(s.pid, ExitReason.Normal);
		const c = cargo();
		s.take(move c);
		s.note(`stopped ${i} payload`);
	}
	await settle(c0 + 600);
	console.log(`stopped cargo=${(cargoGone - c0) / 2}`);

	const reaped: Sink[] = [];
	for (let i = 0; i < 300; i += 1) {
		const s = new Sink();
		stop(s.pid, ExitReason.Normal);
		reaped.push(s);
	}
	await sleepAsync(20);
	c0 = cargoGone;
	for (const s of reaped) {
		const c = cargo();
		s.take(move c);
		s.note("reaped payload");
	}
	await settle(c0 + 600);
	console.log(`reaped cargo=${(cargoGone - c0) / 2}`);

	c0 = cargoGone;
	for (let i = 0; i < 300; i += 1) {
		const s = new Sink();
		s.park();
		const c = cargo();
		s.take(move c);
		s.note(`queued ${i} payload`);
		stop(s.pid, ExitReason.Normal);
	}
	await settle(c0 + 600);
	console.log(`queued cargo=${(cargoGone - c0) / 2}`);
}

await main();
