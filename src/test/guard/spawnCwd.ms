// nim-guard: `execFileCapture(path, args, cwd)` starts the child in `cwd` on
// every backend that runs host programs — C and Raiser. Without it a build tool
// driven from MetaScript shares the caller's cwd-relative `out/` cache with
// every fixture it drives.
//
// WHY A SUBPROCESS: the Raiser half runs only under `msc run --target=raiser`.
// The compiler under test is $MSC when the runner exports one, else `./msc`.
//
// RED PRE-FIX: the fixture fails to build (execFileCapture takes two args).
// GREEN POST-FIX: both targets print SPAWN-CWD-OK.

import { execFileCapture, cwd, exit, env } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
env.set("MSC", msc);
const probe = `${root}/src/test/guard/fixtures/spawnCwdProbe.ms`;

let failed = 0;

for (const target of ["c", "raiser"]) {
	env.set("SPAWN_CWD_TARGET", target);
	const r = execFileCapture(msc, ["run", probe, `--target=${target}`]);
	const out = r.ok ? r.value : r.error.output + r.error.errorOutput;
	if (!out.includes("SPAWN-CWD-OK")) {
		console.log(`GUARD-FAIL ${target}: ${out}`);
		failed = failed + 1;
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
