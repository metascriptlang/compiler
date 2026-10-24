// An array or Buffer whose payload the allocator cannot provide stops the program at the allocation:
// stdout ends at "before the allocation", stderr says "Error: out of memory", exit 1. The lengths are
// under the int32 bound (2 GiB of float64, a 2 GiB Buffer), so the allocator is reached, and the child
// runs under `ulimit -v` of 1 GiB, so malloc returns NULL whatever the host's overcommit policy is.
// Built on the c and danger lanes.
//
// RED MEANS an allocation that returned NULL kept its length over a NULL payload (a later line
// printed, or a crash) or reported a different failure.
//
// Linux only: macOS does not enforce RLIMIT_AS, so it prints GUARD-SKIP there. No SAN cell: ASan
// reserves its shadow memory past any 1 GiB address limit and cannot start under it.

import { execFileResult, cwd, env, exit, platform } from "std/process";
import { ensureDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardOomUnderLimit`;
const limitKb = "1048576";

if (platform != "linux") {
	console.log("GUARD-SKIP RLIMIT_AS is enforced on Linux only");
	exit(0);
}

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

ensureDir(dir);
for (const fixture of ["oomArray", "oomBuffer"]) {
	for (const [lane, flag] of [["c", ""], ["danger", "--danger"]]) {
		const bin = `${dir}/${fixture}.${lane}`;
		const args = ["build", `${root}/src/test/guard/fixtures/${fixture}.ms`, `--output=${bin}`];
		if (flag != "") args.push(flag);
		const built = execFileResult(msc, args, root);
		if (built.exitCode != 0) {
			report(`${fixture} [${lane}]: build failed: ${built.output}${built.errorOutput}`);
			continue;
		}
		const ran = execFileResult("bash", ["-c", `ulimit -v ${limitKb}; exec "$0"`, bin], dir);
		const tag = `${fixture} [${lane}]`;
		if (ran.output != "before the allocation\n") report(`${tag}: stdout ${JSON.stringify(ran.output)}, want only the line before the allocation`);
		if (!ran.errorOutput.includes("Error: out of memory")) report(`${tag}: stderr ${JSON.stringify(ran.errorOutput)} lacks 'Error: out of memory'`);
		if (ran.exitCode != 1) report(`${tag}: exit ${ran.exitCode}, want 1`);
	}
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
