// A program that starts no async work links none of the async runtime: no exit drain, event loop,
// thread pool, actor scheduler or deferred future release. The reference links a facility only
// when a call reaches it, and attaches exit and thread-exit work from the facility that needs it
// (exit procs, thread destruction handlers, a type's own hooks). This builds hello world with
// --lto=off at --danger and --release and reads the linked symbol table: none of the async entry
// points may remain, and `msPrintln` must, so a stripped or empty binary cannot pass.
//
// WHY A SUBPROCESS: the observable is the linked binary's symbols. The compiler under test is
// $MSC, else `./msc`. A host without `nm` prints GUARD-SKIP, which the runner reports as unscored.
//
// RED MEANS: a path every program reaches (main's exit tail, the allocator's thread-exit arm, a
// generic decref) calls into the async runtime directly again instead of through a hook the
// facility sets when it is first used.
// RED PRE-FIX: hello links `msDrainUntilIdle`, `msRunOnce`, `msPoolWorkerLoop`, `msGetDispatcher`,
// `msActorPostJob` (macOS arm64, 2026-11-08). GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, cmdExists, platform } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardHelloLinksNoAsyncRuntime`;

const FORBIDDEN = [
	"msDrainUntilIdle",
	"msRunOnce",
	"msPoolWorkerLoop",
	"msGetDispatcher",
	"msActorPostJob",
	"msCompletionQueuePushReleaseBatch",
];
const REQUIRED = "msPrintln";
const MODES = ["--danger", "--release"];

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
writeFile(`${dir}/hello.ms`, "console.log(\"hello world\");\n");

for (const mode of MODES) {
	const binary = `${dir}/hello${mode.replace("--", "-")}`;
	const build = execFileResult(msc, ["build", "hello.ms", "--mm=drc", mode, "--lto=off", `--output=${binary}`], dir);
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
	const symbols = execFileResult("nm", [path]);
	let sawRequired = false;
	for (const line of symbols.output.split("\n")) {
		const fields = line.trim().split(" ");
		const symbol = fields[fields.length - 1];
		const name = symbol.startsWith("_") ? symbol.slice(1) : symbol;
		if (name == REQUIRED) sawRequired = true;
		if (FORBIDDEN.includes(name)) {
			console.log(`GUARD-FAIL ${mode}: hello links ${name} (${line.trim()})`);
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
