// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: interval: no tick inside a method: true, ticked: true
// @stdout: async loop: no tick inside a method: true, ticked: true
// @stdout: then: no tick inside a method: true, ticked: true
// @serial
// note: each actor is made inside a spawn, so the code it starts there (a setInterval, an
// async loop over sleepAsync, 1000 sleepAsync(...).then callbacks) is registered on a pool
// worker's loop, while busy() is sent from the main thread, which steals the visit, three times. That code
// is the actor's: it runs as one of its jobs, never beside one of its methods (ULTRALOCK A4).
import { stop, ExitReason } from "std/actor";

class Box { n: int64 = 0; }

const one = new Box();

function burn(): boolean {
	const acc = new Box();
	for (let i = 0; i < 20000000; i++) acc.n += one.n;
	return acc.n == 20000000;
}

actor IntervalTicker {
	ticks: int32 = 0;
	id: number = 0;
	start(): void {
		this.id = setInterval(() => { this.ticks = this.ticks + 1; }, 1);
	}
	busy(): boolean {
		const before = this.ticks;
		return burn() && this.ticks == before;
	}
	finish(): boolean {
		clearInterval(this.id);
		return this.ticks > 0;
	}
}

actor LoopTicker {
	ticks: int32 = 0;
	running: boolean = true;
	start(): void {
		const loop = async (): Promise<void> => {
			while (this.running) {
				await sleepAsync(1);
				this.ticks = this.ticks + 1;
			}
		};
		loop();
	}
	busy(): boolean {
		const before = this.ticks;
		return burn() && this.ticks == before;
	}
	finish(): boolean {
		this.running = false;
		return this.ticks > 0;
	}
}

actor ThenTicker {
	ticks: int32 = 0;
	start(): void {
		for (let i = 1; i <= 1000; i++) sleepAsync(i).then(() => { this.ticks = this.ticks + 1; });
	}
	busy(): boolean {
		const before = this.ticks;
		return burn() && this.ticks == before;
	}
	finish(): boolean {
		return this.ticks > 0;
	}
}

actor Anchor {
	ping(): int32 { return 1; }
}

async function main(): Promise<void> {
	one.n = 1;
	const a = new Anchor();
	await a.ping();

	const it = await spawn(() => {
		const t = new IntervalTicker();
		t.start();
		return t;
	});
	await sleepAsync(10);
	let itQuiet = true;
	for (let k = 0; k < 3; k++) itQuiet = (await it.busy()) && itQuiet;
	await sleepAsync(10);
	console.log(`interval: no tick inside a method: ${itQuiet}, ticked: ${await it.finish()}`);
	stop(it.pid, ExitReason.Normal);

	const lt = await spawn(() => {
		const t = new LoopTicker();
		t.start();
		return t;
	});
	await sleepAsync(10);
	let ltQuiet = true;
	for (let k = 0; k < 3; k++) ltQuiet = (await lt.busy()) && ltQuiet;
	await sleepAsync(10);
	console.log(`async loop: no tick inside a method: ${ltQuiet}, ticked: ${await lt.finish()}`);
	stop(lt.pid, ExitReason.Normal);

	const tt = await spawn(() => {
		const t = new ThenTicker();
		t.start();
		return t;
	});
	await sleepAsync(10);
	let ttQuiet = true;
	for (let k = 0; k < 3; k++) ttQuiet = (await tt.busy()) && ttQuiet;
	await sleepAsync(10);
	console.log(`then: no tick inside a method: ${ttQuiet}, ticked: ${await tt.finish()}`);
	stop(tt.pid, ExitReason.Normal);

	stop(a.pid, ExitReason.Normal);
}
main();
