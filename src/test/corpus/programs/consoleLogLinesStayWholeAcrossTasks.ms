// @skip-js: one JS thread prints every line, so no two writers can interleave
// @skip-raiser: the Raiser VM has no thread pool
// @stdout: short lines: 3 runs whole
// @stdout: long lines: 3 runs whole
import { argv, execFileCapture } from "std/process";

const TASKS: int32 = 300;

function lineFor(k: int32, long: boolean): string {
	return "task-" + k.toString() + "-" + "x".repeat(long ? 4000 + k : k % 40);
}

async function printFromTasks(long: boolean): Promise<void> {
	const hs: Promise<int32>[] = [];
	for (let i: int32 = 0; i < TASKS; i += 1) {
		const k = i;
		hs.push(spawn(() => { console.log(lineFor(k, long)); return k; }));
	}
	let s: int32 = 0;
	for (const h of hs) { s += await h; }
	console.log(`sum=${s}`);
}

function wholeLines(out: string, long: boolean): boolean {
	const seen: boolean[] = new Array(TASKS);
	for (let k: int32 = 0; k < TASKS; k += 1) seen[k] = false;
	let sumLine = false;
	for (const line of out.split("\n")) {
		if (line == "") continue;
		if (line == "sum=44850") { sumLine = true; continue; }
		if (!line.startsWith("task-")) return false;
		const dash = line.indexOf("-", 5);
		if (dash < 0) return false;
		const k = parseInt(line.slice(5, dash)) as int32;
		if (k < 0 || k >= TASKS || seen[k] || line != lineFor(k, long)) return false;
		seen[k] = true;
	}
	for (let k: int32 = 0; k < TASKS; k += 1) if (!seen[k]) return false;
	return sumLine;
}

function check(long: boolean): string {
	let whole: int32 = 0;
	for (let run: int32 = 0; run < 3; run += 1) {
		const child = execFileCapture(argv[0], [long ? "long" : "short"]);
		if (child.ok && wholeLines(child.value, long)) whole += 1;
	}
	return `${long ? "long" : "short"} lines: ${whole == 3 ? "3 runs whole" : `${whole} of 3 runs whole`}`;
}

if (argv.length > 1) {
	await printFromTasks(argv[1] == "long");
} else {
	console.log(check(false));
	console.log(check(true));
}
