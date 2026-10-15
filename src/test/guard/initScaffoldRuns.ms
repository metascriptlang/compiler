// `msc init` writes a project whose first `msc run` prints the scaffold's greeting, on C and on JS.
//
// WHY A SUBPROCESS: the observable is what a new user sees from `msc init` then `msc run`, which no
// in-process test reaches. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: both runs exit 0 and print no greeting, because nothing called the scaffold's `main()`.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardInitScaffoldRuns`;

let failed = 0;

removeAll(dir);
const init = execFileResult(msc, ["init", dir]);
if (init.exitCode != 0) {
	console.log(`GUARD-FAIL init: ${init.output}${init.errorOutput}`);
	exit(1);
}
for (const target of ["c", "js"]) {
	const r = execFileResult(msc, ["run", `--target=${target}`, "src/index.ms"], dir);
	if (r.exitCode != 0 || !r.output.includes("hello, metascript!")) {
		console.log(`GUARD-FAIL ${target}: exit ${r.exitCode}: ${r.output}${r.errorOutput}`);
		failed = failed + 1;
	}
}
if (failed != 0) exit(1);
console.log("GUARD-OK");
