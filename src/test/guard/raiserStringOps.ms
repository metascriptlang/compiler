// A string operation on statically string operands (concat, byteAt, a string Map key) gives the same
// result on the Raiser as on native, including the mixed concat, `s = s + s` and equal keys with
// different handles. The fixture is run by both and each output is compared with the expected text.
//
// RED when a typed string opcode reads a handle as the wrong kind, appends in place into its own suffix,
// or hashes or compares a key by handle instead of by text.

import { execFileResult, cwd, env, exit } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const fixture = `${root}/src/test/guard/fixtures/raiserStringOps.ms`;
const expected = "xy a1 a1 64 abab t7u\n104 195 169 -1 -1 -1\n1 12 true true false\n";

let failed = 0;

for (const args of [["run", "--target=raiser", fixture], ["run", fixture]]) {
	const run = execFileResult(msc, args);
	const out = run.output.slice(run.output.length - expected.length, run.output.length);
	if (run.exitCode != 0 || out != expected) {
		console.log(`GUARD-FAIL ${args.join(" ")}: exit ${run.exitCode}: ${run.output}${run.errorOutput}`);
		failed = failed + 1;
	}
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
