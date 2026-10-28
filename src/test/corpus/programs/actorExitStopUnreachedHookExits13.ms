// @exit: 13
// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
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
