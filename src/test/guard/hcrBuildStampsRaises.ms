// An HCR build gives every call a raises verdict before emission, so a hot-reload build of any
// program reaches the C compiler under parallel and serial emit alike.
//
// WHY A SUBPROCESS: the observable is the exit of `msc build --hcr`. The compiler under test is
// $MSC, else `./msc`.
//
// RED PRE-FIX: every cell failed with "a call at <line> reached emission without a raises
// verdict", one error per emit job that met an unstamped call. GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardHcrRaises`;

let failed = 0;

function build(label: string, source: string, jobs: string[]): void {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	writeFile(`${cell}/main.ms`, source);
	const args = ["build", "--hcr", "main.ms", "--output=main"];
	for (const j of jobs) args.push(j);
	const built = execFileResult(msc, args, cell);
	if (built.exitCode != 0) {
		console.log(`GUARD-FAIL ${label}: msc build --hcr exited ${built.exitCode.toString()}\n${built.output}${built.errorOutput}`);
		failed = failed + 1;
	}
}

const hello = "console.log(\"hello\");\n";
const readBeforeInit = "bump();\nlet count: int32 = 5;\nfunction bump(): void { count += 1; }\nconsole.log(count);\n";

removeAll(dir);
ensureDir(dir);
build("helloParallel", hello, []);
build("helloSerial", hello, ["--emit-jobs=1"]);
build("readBeforeInitParallel", readBeforeInit, []);
build("readBeforeInitSerial", readBeforeInit, ["--emit-jobs=1"]);
removeAll(dir);

if (failed > 0) exit(1);
console.log("GUARD-OK");
