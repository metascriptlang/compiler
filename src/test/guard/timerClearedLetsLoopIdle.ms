// guard: a cleared timer does not keep its loop from going idle
//
// INVARIANT (ULTRALOCK A8, the exit drain): a program ends once nothing can settle; a timer
//   cleared before it fires settles nothing, so it holds neither the main loop nor the pool
//   whether a function, an actor or a pool worker armed it, as Node's clearTimeout does.
//
// WHY A SUBPROCESS: the observable is how long the built program takes to exit after its
//   last line. The compiler under test is $MSC, else `./msc`.
//
// RED MEANS: a child printed its line and then waited about DELAY_MS before exiting: the idle
//   test of dispatchFull.c counted a cancelled heap entry (msMainLoopIdle, msTimerDelayFrom,
//   or the pool's pending count for a worker heap).

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardTimerClearedLetsLoopIdle`;
const DELAY_MS = 3000;
const EXIT_BUDGET_MS = 1500;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function exitsPromptly(label: string, source: string, expected: string): void {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	writeFile(`${cell}/main.ms`, source);
	const built = execFileResult(msc, ["build", "main.ms", "--output=main"], cell);
	if (built.exitCode != 0) {
		report(`${label}: build failed: ${built.output}${built.errorOutput}`);
		return;
	}
	const t0 = Date.now();
	const run = execFileResult(`${cell}/main`, [], cell);
	const elapsed = Date.now() - t0;
	if (run.exitCode != 0 || !run.output.contains(expected)) report(`${label}: exit ${run.exitCode}, output '${run.output}${run.errorOutput}'`);
	if (elapsed >= EXIT_BUDGET_MS) report(`${label}: exited after ${elapsed} ms with a ${DELAY_MS} ms timer cleared`);
}

exitsPromptly("clearTimeout",
	`const id = setTimeout(() => { console.log("fired"); }, ${DELAY_MS});\nclearTimeout(id);\nconsole.log("timeout cleared");\n`,
	"timeout cleared");

exitsPromptly("clearInterval",
	`const id = setInterval(() => { console.log("tick"); }, ${DELAY_MS});\nclearInterval(id);\nconsole.log("interval cleared");\n`,
	"interval cleared");

exitsPromptly("actor",
	"actor Clock {\n"
	+ `\tarmAndClear(): string {\n\t\tconst id = setTimeout(() => { console.log("fired"); }, ${DELAY_MS});\n\t\tclearTimeout(id);\n\t\treturn "actor cleared";\n\t}\n}\n`
	+ "const c = new Clock();\nconsole.log(await c.armAndClear());\n",
	"actor cleared");

exitsPromptly("workerArmsMainClears",
	`function arm(): number {\n\treturn setTimeout(() => { console.log("worker timer fired"); }, ${DELAY_MS});\n}\n`
	+ "const id = await spawn(arm);\nclearTimeout(id);\nconsole.log(\"cleared from main\");\n",
	"cleared from main");

exitsPromptly("workerClearsBesideLive",
	`function arm(): int32 {\n\tconst id = setTimeout(() => { console.log("never"); }, ${DELAY_MS});\n\tclearTimeout(id);\n\tsetTimeout(() => { console.log("worker live fired"); }, 100);\n\treturn 1;\n}\n`
	+ "console.log(`spawned ${await spawn(arm)}`);\n",
	"worker live fired");

if (failed != 0) exit(1);
console.log("GUARD-OK");
