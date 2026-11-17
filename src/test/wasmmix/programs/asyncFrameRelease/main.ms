// @columns: c,mixed
// @stdout: destroyed q1
// @stdout: quick 3
// @stdout: destroyed p1
// @stdout: holds 3
// @stdout: done
import { holds, quick } from "./asyncFrameReleaseWasm";

async function run(): Promise<void> {
	console.log(`quick ${await quick(1)}`);
	console.log(`holds ${await holds(1)}`);
}
run().then(() => { console.log("done"); });
