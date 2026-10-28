// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: logger terminate 1
// note: Waiter is suspended at exit on a promise nothing can settle and has no onTerminate to lose, so the program ends with its own exit code, as an unsettled promise does on Node; Logger is still stopped and runs its hook (ULTRALOCK A8). Sibling with a hook: actorExitStopUnreachedHookExits13.
import { ExitReason } from "std/actor";

actor Waiter {
	wait(): void {
		await new Promise<void>((resolve) => {});
		console.log("after await");
	}
}

actor Logger {
	lines: int32 = 0;

	log(): int32 {
		this.lines += 1;
		return this.lines;
	}

	onTerminate(reason: ExitReason): void {
		console.log(`logger terminate ${this.lines}`);
	}
}

const w = new Waiter();
const l = new Logger();
w.wait();
console.log(`logged ${await l.log()}`);
console.log("end of main");
