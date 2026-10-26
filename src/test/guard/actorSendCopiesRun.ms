// A send carries a closure over copies, and an object of scalars, to the actor
//
// INVARIANT (ULTRALOCK V0, V1): a Sendable closure sent without a reply may capture copies (a
//   number, a string), and an object whose fields are plain data crosses by its own rule. An
//   Arc<T> capture: actorReplyArcRuns.ms.
//   Borrowed captures are refused (actorSendClosureBorrowRejects.ms).
//
// RED MEANS: the send rule refuses a copy-only closure or a closure with no capture.
//
// GUARD-JS

import { stop, ExitReason } from "std/actor";

interface Pt { x: int32; y: int32; }

actor W {
	total: int32 = 0;
	run(f: Sendable<() => int32>): void { this.total = this.total + f(); }
	at(p: Pt): int32 { return p.x + p.y; }
	done(): int32 { return this.total; }
}

function constant(): int32 { return 1; }

function send(w: W, k: int32, label: string): void {
	const n = k + 1;
	w.run(() => n);
	w.run(() => label.length as int32);
	w.run(() => 1);
	w.run(constant);
}

async function main(): Promise<void> {
	const w = new W();
	send(w, 1, "abc");
	const p: Pt = { x: 1, y: 2 };
	const at = await w.at(p);
	const t = await w.done();
	stop(w.pid, ExitReason.Normal);
	if (t != 7 || at != 3) throw new Error(`send: t=${t} at=${at}`);
	console.log("GUARD-OK");
}

await main();
