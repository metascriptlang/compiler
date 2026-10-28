// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: terminate n=2 shutdown=true
// note: the actor is never stopped; program exit stops it with ExitReason.Shutdown, so its onTerminate runs after the entry module's last line (ULTRALOCK A8).
import { ExitReason } from "std/actor";

actor Counter {
	n: int32 = 0;

	bump(): int32 {
		this.n += 1;
		return this.n;
	}

	onTerminate(reason: ExitReason): void {
		console.log(`terminate n=${this.n} shutdown=${reason == ExitReason.Shutdown}`);
	}
}

const c = new Counter();
console.log(`bump ${await c.bump()}`);
console.log(`bump ${await c.bump()}`);
console.log("end of main");
