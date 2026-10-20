// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: send-then-stop 200
// @stdout: stop-only 200
// @stdout: timer-then-stop 200
import { stop, ExitReason } from "std/actor";
import { sleepAsync } from "std/core/promise";

actor Worker {
	n: int32;
	constructor() {
		this.n = 0;
	}
	work(): void {
		const r = await spawn(() => 1);
		this.n = this.n + r;
	}
	ping(): void {
		this.n = this.n + 1;
	}
}

async function main(): Promise<void> {
	let a = 0;
	for (let i = 0; i < 200; i = i + 1) {
		const w = new Worker();
		w.work();
		const z = await spawn(() => 0);
		w.ping();
		stop(w.pid, ExitReason.Normal);
		a = a + 1 + z;
	}
	console.log("send-then-stop " + a.toString());

	let b = 0;
	for (let i = 0; i < 200; i = i + 1) {
		const w = new Worker();
		w.work();
		const z = await spawn(() => 0);
		stop(w.pid, ExitReason.Normal);
		b = b + 1 + z;
	}
	console.log("stop-only " + b.toString());

	let c = 0;
	for (let i = 0; i < 200; i = i + 1) {
		const w = new Worker();
		w.work();
		await sleepAsync(1);
		w.ping();
		stop(w.pid, ExitReason.Normal);
		c = c + 1;
	}
	console.log("timer-then-stop " + c.toString());
}
main();
