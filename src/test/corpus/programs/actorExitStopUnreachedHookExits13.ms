// @exit: 13
// @xfail(raiser): the Raiser runs the hook of an actor parked on an unsettled await at exit (prints terminate 1) instead of warning and exiting 13, and leaks its job closures
// @stdout: end of main
// note: save() is suspended at exit on a promise nothing can settle, so its method never finishes and its onTerminate can never run; the program ends with a warning naming the actor and exit 13 instead of hanging or dropping the hook silently (ULTRALOCK A8). Sibling without a hook: actorExitStopParkedWithoutHookEndsQuietly.
import { ExitReason } from "std/actor";

actor Saver {
	n: int32 = 0;

	save(): void {
		this.n = 1;
		await new Promise<void>((resolve) => {});
		console.log("after await");
	}

	onTerminate(reason: ExitReason): void {
		console.log(`terminate ${this.n}`);
	}
}

const s = new Saver();
s.save();
console.log("end of main");
