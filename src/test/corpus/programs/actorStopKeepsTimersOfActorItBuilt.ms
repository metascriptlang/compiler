// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: child ticks after parent stop: true
// note: Parent builds Child inside one of its methods, and Child's constructor arms an
// interval. That interval is Child's, so stopping Parent leaves it ticking (ULTRALOCK A4).
import { stop, ExitReason } from "std/actor";

actor Child {
	ticks: int32 = 0;
	id: number = 0;
	constructor() {
		this.id = setInterval(() => { this.ticks = this.ticks + 1; }, 1);
	}
	count(): int32 {
		return this.ticks;
	}
	finish(): int32 {
		clearInterval(this.id);
		return this.ticks;
	}
}

actor Parent {
	make(): Child {
		return new Child();
	}
}

async function main(): Promise<void> {
	const p = new Parent();
	const c = await p.make();
	stop(p.pid, ExitReason.Normal);
	const atStop = await c.count();
	await sleepAsync(50);
	console.log(`child ticks after parent stop: ${(await c.finish()) > atStop}`);
	stop(c.pid, ExitReason.Normal);
}
main();
