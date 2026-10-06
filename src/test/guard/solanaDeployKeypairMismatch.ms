// The deploy keypair (its public half, bytes 32-63 of the solana-keygen JSON) must hold the declared
// program id, as `anchor keys sync` keeps declare_id! equal to it; the fixture holds another id.
// RED MEANS: a build deploys at one address while its entry checks another, so every call fails 4100.
//
// WHY A SUBPROCESS: a `-d:programKeypair` path without a build.ms is read against the working
// directory, as a command-line path is, and the guard runner builds each probe in a sandbox. The
// build runs from the repo root with the compiler under test ($MSC, else `./msc`).

import { execFileResult, cwd, exit, env } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

const built = execFileResult(msc, [
	"build",
	"-d:programId=B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32",
	"-d:programKeypair=src/test/guard/solanaDeployKeypair.json",
	`${root}/src/test/guard/fixtures/solanaDeployKeypairProgram.ms`,
	"--os=solana",
	`--output=${root}/out/guardSolanaDeployKeypair/prog.so`,
], root);
const said = built.output + built.errorOutput;
if (built.exitCode != 0 && said.includes("--os=solana requires ")) {
	console.log("GUARD-SKIP no SBF toolchain on this host");
	exit(0);
}
let failed = 0;
for (const want of [
	"the build declares programId B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32, but the deploy keypair",
	"is program Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS: set programId to Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS",
]) {
	if (built.exitCode == 0 || !said.includes(want)) {
		console.log(`GUARD-FAIL missing diagnostic: ${want} (exit ${built.exitCode}): ${said}`);
		failed = failed + 1;
	}
}
if (failed != 0) exit(1);
console.log("GUARD-OK");
