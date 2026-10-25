// The Raiser tier of std/process keeps the processChild* guards' contracts: each one listed
// prints GUARD-OK under `msc run --target=raiser`, through the host bridges over the same runtime the C
// tier links. Not listed: processChildDroppedHandle, because Raiser runs no onDestroy, so a dropped
// handle's child lives until the run ends (raiserChildVmEnd covers that end); and
// processChildSiblingSpawn, because Raiser has no msPromiseAll bridge.
//
// WHY A SUBPROCESS: the guard runner builds each guard for C; the Raiser half runs only under
// `msc run --target=raiser`. The compiler under test is $MSC when the runner exports one, else `./msc`.
//
// RED on a compiler without `spawn` in the Raiser tier of std/process (every cell fails to build).

import { execFileResult, cwd, env, exit } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

const guards = [
	"processChildEcho",
	"processChildStderrFlood",
	"processChildStdoutFloodWhileWriting",
	"processChildHungKill",
	"processChildDeadStdin",
	"processChildOverflow",
	"processChildUtf8Split",
];

let failed = 0;

for (const name of guards) {
	const run = execFileResult(msc, ["run", "--target=raiser", `${root}/src/test/guard/${name}.ms`]);
	const out = run.output + run.errorOutput;
	if (run.exitCode != 0 || run.signal != 0 || !out.contains("GUARD-OK")) {
		console.log(`GUARD-FAIL ${name} [raiser] {${run.exitCode}, ${run.signal}}: ${out}`);
		failed = failed + 1;
	}
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
