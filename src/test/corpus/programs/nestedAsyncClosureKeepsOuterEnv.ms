// @stdout: method this ticks=1
// @stdout: param object n=1
// @stdout: two levels up total=6
// @stdout: actor ticked=1
// note: an async closure made inside a synchronous closure reads what the routine around them captured after its first await, once that routine has returned: the receiver, an object parameter, a local two env levels up, and the receiver of an actor job.

import { sleepAsync } from "std/core/promise";

class Ticker {
	ticks: int32 = 0;
	start(): Promise<void> {
		const job = (): Promise<void> => {
			const step = async (): Promise<void> => {
				await sleepAsync(1);
				this.ticks = this.ticks + 1;
			};
			return step();
		};
		return job();
	}
}

class Box {
	n: int32 = 0;
}

function bump(b: Box): Promise<void> {
	const job = (): Promise<void> => {
		const step = async (): Promise<void> => {
			await sleepAsync(1);
			b.n = b.n + 1;
		};
		return step();
	};
	return job();
}

function sumLater(base: int32): Promise<int32> {
	const outer = (): Promise<int32> => {
		const extra = base + 1;
		const inner = (): Promise<int32> => {
			const step = async (): Promise<int32> => {
				await sleepAsync(1);
				return base + extra + 3;
			};
			return step();
		};
		return inner();
	};
	return outer();
}

actor Counter {
	ticks: int32 = 0;
	start(): void {
		const step = async (): Promise<void> => {
			await sleepAsync(1);
			this.ticks = this.ticks + 1;
		};
		step();
	}
	read(): int32 {
		return this.ticks;
	}
}

async function main(): Promise<void> {
	const t = new Ticker();
	await t.start();
	console.log(`method this ticks=${t.ticks}`);
	const b = new Box();
	await bump(b);
	console.log(`param object n=${b.n}`);
	console.log(`two levels up total=${await sumLater(1)}`);
	const c = new Counter();
	c.start();
	await sleepAsync(20);
	console.log(`actor ticked=${await c.read()}`);
}
main();
