// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @xfail(js): the JS mailbox pump marks the running actor only for a method's synchronous part, so an interval armed in a constructor or after an await is nobody's and ticks after stop
// @xfail(esm): the same JS gap as @xfail(js)
// @stdout: constructor: stopped
// @stdout: after await: stopped
// @stdout: exit after stop
// @serial
// note: each actor arms an interval outside a method's synchronous part, in its constructor
// or after an await, then stops itself. Stop cancels the actor's timers, so no tick runs
// after it; a tick that does prints "tick after stop" and clears itself (ULTRALOCK A4).
import { stop, ExitReason } from "std/actor";

actor CtorTicker {
	ticks: int32 = 0;
	stopped: boolean = false;
	id: number = 0;
	constructor() {
		this.id = setInterval(() => {
			if (this.stopped) {
				console.log("constructor: tick after stop");
				clearInterval(this.id);
			}
			this.ticks = this.ticks + 1;
		}, 1);
	}
	stopSelf(): void {
		this.stopped = true;
		stop(this.pid, ExitReason.Normal);
	}
}

actor AwaitTicker {
	ticks: int32 = 0;
	stopped: boolean = false;
	id: number = 0;
	start(): void {
		const arm = async (): Promise<void> => {
			await sleepAsync(1);
			this.id = setInterval(() => {
				if (this.stopped) {
					console.log("after await: tick after stop");
					clearInterval(this.id);
				}
				this.ticks = this.ticks + 1;
			}, 1);
		};
		arm();
	}
	stopSelf(): void {
		this.stopped = true;
		stop(this.pid, ExitReason.Normal);
	}
}

async function main(): Promise<void> {
	const c = new CtorTicker();
	await sleepAsync(5);
	c.stopSelf();
	await sleepAsync(20);
	console.log("constructor: stopped");

	const a = new AwaitTicker();
	a.start();
	await sleepAsync(5);
	a.stopSelf();
	await sleepAsync(20);
	console.log("after await: stopped");
	console.log("exit after stop");
}
main();
