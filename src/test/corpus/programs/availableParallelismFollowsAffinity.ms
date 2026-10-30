// note: os.availableParallelism() counts the CPUs the process may run on, as node's os.availableParallelism() does on Linux, and the thread pool sizes itself from the same count; before it, the pool counted every online CPU, so a job confined to two cores still ran as many cc jobs as the host has CPUs.
// Axes: an unrestricted run counts at most the online CPUs (a confined host counts fewer), run under `taskset -c 0` reports 1.
//
// @skip-js: the JS backend has no std/os availableParallelism
// @stdout: unrestricted ok
// @stdout: pinned 1
import { argv, execFileCapture, platform } from "std/process";
import { availableParallelism, cpuCount } from "std/os";

if (argv.length > 1) {
	console.log(`${availableParallelism()}`);
} else if (platform != "linux") {
	console.log("unrestricted ok");
	console.log("pinned 1");
} else {
	console.log(availableParallelism() >= 1 && availableParallelism() <= cpuCount() ? "unrestricted ok" : `unrestricted ${availableParallelism()} of ${cpuCount()}`);
	const child = execFileCapture("taskset", ["-c", "0", argv[0], "child"]);
	console.log(child.ok ? `pinned ${child.value.trim()}` : `pinned failed ${child.error.message}`);
}
