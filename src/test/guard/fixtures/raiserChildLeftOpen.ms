// Driven by raiserChildVmEnd.ms under `msc run --target=raiser`: starts a child that never ends,
// prints its pid and leaves its handle open, then ends the run the way argv[1] names.

import { spawn, argv, exit } from "std/process";
import { host } from "./childHost";

const started = spawn(host("sleep"), ["1000"]);
if (!started.ok) {
	console.log(`SPAWN-FAILED ${started.error.message}`);
	exit(2);
}
const child = started.value;
console.log(`PID ${child.pid}`);
const how = argv.length > 1 ? argv[1] : "end";
if (how == "throw") throw new Error("left a child open");
if (how == "exit") exit(3);
