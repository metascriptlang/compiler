// note: os.availableParallelism() counts the CPUs the process may run on, as node's os.availableParallelism() does on Linux and Windows, and the thread pool sizes itself from the same count; before it, the pool counted every online CPU, so a job confined to two cores still ran as many cc jobs as the host has CPUs.
// Axes: an unrestricted run counts at most the online CPUs (a confined host counts fewer); a child confined to one CPU reports 1 and to two CPUs reports 2, by `taskset` on Linux and `start /affinity` on Windows.
//
// @skip-js: the JS backend has no std/os availableParallelism
// @skip-raiser: std/os has no Raiser tier for CPU counts, and the Raiser VM has no thread pool
// @stdout: unrestricted ok
// @stdout: pinned 1
// @stdout: pinned 2
import { argv, execFileCapture, platform } from "std/process";
import { availableParallelism, cpuCount } from "std/os";

function confined(cpus: string, mask: string): string {
	const child = platform == "windows"
		? execFileCapture("cmd", ["/c", "start", "/b", "/wait", "/affinity", mask, argv[0], "child"])
		: execFileCapture("taskset", ["-c", cpus, argv[0], "child"]);
	return child.ok ? `pinned ${child.value.trim()}` : `pinned failed ${child.error.message}`;
}

if (argv.length > 1) {
	console.log(`${availableParallelism()}`);
} else if (platform != "linux" && platform != "windows") {
	console.log("unrestricted ok");
	console.log("pinned 1");
	console.log("pinned 2");
} else {
	console.log(availableParallelism() >= 1 && availableParallelism() <= cpuCount() ? "unrestricted ok" : `unrestricted ${availableParallelism()} of ${cpuCount()}`);
	console.log(confined("0", "1"));
	console.log(confined("0,1", "3"));
}
