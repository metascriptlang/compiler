// An actor replies with an Arc, and a sent closure captures one
//
// INVARIANT (ULTRALOCK V0, V7): SHARE crosses by its atomic count, so an Arc<T> field may be the
//   reply, and a closure sent without a reply may capture an Arc<T>. C only: Arc<T> has no JS
//   binding (corpus 415-arcActorBoundary).
//
// RED MEANS: the reply or send rule refuses an Arc<T>.

import { stop, ExitReason } from "std/actor";

struct Payload { buf: string; n: int32; }

actor Keeper {
	shared: Arc<Payload> = new Arc({ buf: "kept", n: 4 });
	total: int32 = 0;
	share(): Arc<Payload> { return this.shared; }
	run(f: Sendable<() => int32>): void { this.total = this.total + f(); }
	done(): int32 { return this.total; }
}

function send(k: Keeper, p: Arc<Payload>): void {
	k.run(() => p.n);
}

async function main(): Promise<void> {
	const k = new Keeper();
	const sh = await k.share();
	send(k, new Arc({ buf: "sent", n: 3 }));
	const t = await k.done();
	stop(k.pid, ExitReason.Normal);
	if (sh.n != 4 || t != 3) throw new Error(`arc: sh=${sh.n} t=${t}`);
	console.log("GUARD-OK");
}

await main();
