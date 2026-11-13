// @stdout: kicked 3
// @stdout: stopped
// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// note: an actor is stopped while Promise.all, race and any it started still wait on inputs that never
// settle. The stop drops each combinator's pending work on the actor and releases the inputs it holds
// (ULTRALOCK A4); the sanitizer lane's ledger shows nothing left.

import { stop, ExitReason } from "std/actor";

actor Pong {
	back(n: int32): int32 { return n + 1; }
}

function never(): Promise<int32> {
	return new Promise<int32>((settle) => {});
}

actor Fan {
	peer: Pong | null = null;
	meet(peer: Pong): void { this.peer = peer; }
	kick(): int32 {
		const all = Promise.all([never(), this.peer!.back(1)]);
		const race = Promise.race([never(), never()]);
		const any = Promise.any([never(), never()]);
		return 3;
	}
}

async function main(): Promise<void> {
	const fan = new Fan();
	const pong = new Pong();
	fan.meet(pong);
	console.log(`kicked ${await fan.kick()}`);
	stop(fan.pid, ExitReason.Normal);
	stop(pong.pid, ExitReason.Normal);
	console.log("stopped");
}

await main();
