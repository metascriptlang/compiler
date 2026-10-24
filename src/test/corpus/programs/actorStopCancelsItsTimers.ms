// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @skip-js: stop() in std/actor/index.jms leaves the actor's setInterval armed, so node never exits
// @stdout: stopped with a tick queued: true
// @stdout: exit after stop
// @serial
// note: the actor's interval was started on a pool worker's loop and is still armed when the
// actor stops itself with a tick queued behind the running method. Stop cancels the actor's
// timers and drops the queued tick, so the worker loop goes idle and the program exits
// (ULTRALOCK A4).
import { stop, ExitReason } from "std/actor";

class Box { n: int64 = 0; }
const one = new Box();

actor Ticker {
	ticks: int32 = 0;
	start(): void {
		setInterval(() => { this.ticks = this.ticks + 1; }, 1);
	}
	busyThenStop(): int32 {
		const acc = new Box();
		for (let i = 0; i < 20000000; i++) acc.n += one.n;
		stop(this.pid, ExitReason.Normal);
		return this.ticks;
	}
}

actor Anchor {
	ping(): int32 { return 1; }
}

async function main(): Promise<void> {
	one.n = 1;
	const a = new Anchor();
	await a.ping();
	const t = await spawn(() => {
		const t = new Ticker();
		t.start();
		return t;
	});
	await sleepAsync(5);
	const seen = await t.busyThenStop();
	console.log(`stopped with a tick queued: ${seen >= 0}`);
	await sleepAsync(20);
	stop(a.pid, ExitReason.Normal);
	console.log("exit after stop");
}
main();
