// A Raiser run kills and reaps every child it left open when it ends: by an uncaught throw, by
// process.exit, or by falling off the end with the handle still held. The child is gone from the
// process table once `msc run --target=raiser` returns.
//
// WHY A SUBPROCESS: the Raiser run ends only when `msc run --target=raiser` does.
// The compiler under test is $MSC when the runner exports one, else `./msc`.
//
// RED when runRaiser skips closeHostChildren: the child outlives msc, reparented and still listed.
// RED on a compiler without `spawn` in the Raiser tier of std/process (the fixture fails to build).

import { execFileResult, cwd, env, exit } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const fixture = `${root}/src/test/guard/fixtures/raiserChildLeftOpen.ms`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function listed(pid: string): string {
	return execFileResult("/bin/ps", ["-o", "stat=", "-p", pid]).output.trim();
}

for (const how of ["throw", "exit", "end"]) {
	const run = execFileResult(msc, ["run", "--target=raiser", fixture, how]);
	const out = run.output + run.errorOutput;
	const at = out.indexOf("PID ");
	if (at < 0) {
		report(`${how}: no pid printed: ${out}`);
		continue;
	}
	const pid = out.slice(at + 4, out.length).split("\n")[0].trim();
	const state = listed(pid);
	if (state != "") {
		report(`${how}: child ${pid} outlived the run: '${state}'`);
		execFileResult("/bin/kill", ["-9", pid]);
	}
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
