// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: saved 1
// @stdout: terminate saved=1
// note: the entry module ends while save() is suspended on its timer; the method finishes before program exit runs onTerminate (ULTRALOCK A7, A8).
import { ExitReason } from "std/actor";
import { sleepAsync } from "std/core/promise";

actor Saver {
	saved: int32 = 0;

	save(): void {
		await sleepAsync(20);
		this.saved += 1;
		console.log(`saved ${this.saved}`);
	}

	onTerminate(reason: ExitReason): void {
		console.log(`terminate saved=${this.saved}`);
	}
}

const s = new Saver();
s.save();
console.log("end of main");
