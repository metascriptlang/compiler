// A program that awaits timers on its own loop and spawns nothing links no thread pool: waking a
// pool worker reads the pool that exists and never creates one, because only a spawn or the actor
// system starts the pool. This builds a setTimeout + async/await program with --lto=off at
// --danger and --release, runs it, and reads the linked symbol table: `msPoolWorkerLoop` may not
// remain, and `msRunOnce` must, so a program that no longer reaches the event loop cannot pass.
//
// WHY A SUBPROCESS: the observable is the linked binary's symbols. The compiler under test is
// $MSC, else `./msc`. A host without `nm` prints GUARD-SKIP, which the runner reports as unscored.
//
// RED MEANS: a wake, peek or count of the pool (`msPoolWakeWorker`, reached from a future's
// deferred release) calls `msPoolGet()` again, whose first call starts the workers.
// RED PRE-FIX: links `msPoolWorkerLoop` at both modes (macOS arm64, tree 939e207b0891,
// 2026-11-12). GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, cmdExists, platform } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardAsyncTimerLinksNoPool`;

const FORBIDDEN = "msPoolWorkerLoop";
const REQUIRED = "msRunOnce";
const MODES = ["--danger", "--release"];
const PROGRAM = `function delay(ms: int32): Promise<int32> {
	return new Promise<int32>((resolve) => { setTimeout(() => resolve(ms), ms); });
}
async function run(): Promise<void> {
	const a = await delay(5);
	const b = await delay(10);
	console.log("done", a + b);
}
run();
`;

let failed = 0;

if (!cmdExists("nm")) {
	console.log("GUARD-SKIP nm is not on PATH");
	exit(0);
}
if (platform == "windows") {
	console.log("GUARD-SKIP the Windows link keeps its symbols in a .pdb, which nm does not read");
	exit(0);
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/timers.ms`, PROGRAM);

for (const mode of MODES) {
	const binary = `${dir}/timers${mode.replace("--", "-")}`;
	const build = execFileResult(msc, ["build", "timers.ms", "--mm=drc", mode, "--lto=off", `--output=${binary}`], dir);
	if (build.exitCode != 0) {
		console.log(`GUARD-FAIL ${mode}: build failed\n${build.output}${build.errorOutput}`);
		failed = failed + 1;
		continue;
	}
	const path = exists(`${binary}.exe`) ? `${binary}.exe` : binary;
	if (!exists(path)) {
		console.log(`GUARD-FAIL ${mode}: ${msc} exited 0 without writing ${path}`);
		failed = failed + 1;
		continue;
	}
	const run = execFileResult(path, []);
	if (run.exitCode != 0 || run.output.trim() != "done 15") {
		console.log(`GUARD-FAIL ${mode}: the program exited ${run.exitCode} printing "${run.output.trim()}", expected "done 15"`);
		failed = failed + 1;
	}
	const symbols = execFileResult("nm", [path]);
	let sawRequired = false;
	for (const line of symbols.output.split("\n")) {
		const fields = line.trim().split(" ");
		const symbol = fields[fields.length - 1];
		const name = symbol.startsWith("_") ? symbol.slice(1) : symbol;
		if (name == REQUIRED) sawRequired = true;
		if (name == FORBIDDEN) {
			console.log(`GUARD-FAIL ${mode}: an await on timers links ${name} (${line.trim()})`);
			failed = failed + 1;
		}
	}
	if (!sawRequired) {
		console.log(`GUARD-FAIL ${mode}: no ${REQUIRED} in the symbol table, so the check read nothing`);
		failed = failed + 1;
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
