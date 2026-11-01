// Keep the Node consumers in src/test/js/declaration*/ reachable from the
// guard lane; the native JS test index cannot execute their .mjs runners.
import { execFileResult, cwd, exit, env } from "std/process";
import { exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const candidate = mscEnv != "" ? mscEnv : `${root}/msc`;
const msc = exists(`${candidate}.exe`) ? `${candidate}.exe` : candidate;

function runNode(label: string, args: string[]): void {
	const result = execFileResult("node", args, root);
	if (!result.started || !result.pipeOk || result.signal != 0 ||
		result.exitCode != 0) {
		console.log(`GUARD-FAIL ${label}: started=${result.started}, ` +
			`pipeOk=${result.pipeOk}, signal=${result.signal}, ` +
			`exit=${result.exitCode}, errno=${result.startErrno}`);
		console.log(result.output);
		console.log(result.errorOutput);
		exit(1);
	}
	console.log(result.output);
	if (result.errorOutput != "") console.log(result.errorOutput);
}

if (!exists(msc) || !env.set("MSC", msc)) {
	console.log(`GUARD-FAIL candidate compiler unavailable: ${msc}`);
	exit(1);
}
const oracle = `${root}/out/compat/typescript/oracle/lib/typescript.js`;
if (!exists(oracle)) {
	runNode("pinned TypeScript oracle provisioning", [
		"src/test/compat/typescript/run.mjs", "fetch",
	]);
}
runNode("declaration CLI/class/default/source/package consumers", [
	"--test",
	"--test-concurrency=1",
	"src/test/js/declarationCli/run.mjs",
	"src/test/js/declarationCli/classRun.mjs",
	"src/test/js/declarationDefaults/run.mjs",
	"src/test/js/declarationSource/run.mjs",
	"src/test/js/declarationPackage/run.mjs",
]);
console.log("GUARD-OK");
