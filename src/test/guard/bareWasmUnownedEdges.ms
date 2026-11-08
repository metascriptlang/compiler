// A 32-bit target counts Unowned<T> edges as a 64-bit one does: on freestanding Wasm a read through an edge
// whose target was destroyed traps while the same program without that read runs, and 16384 targets
// destroyed under an edge fit a 1 MiB memory only because each husk returns when its last edge goes.
// RED MEANS 32-bit has no Unowned count again (the dead read returns the freed object) or a husk is kept.
import { cwd, env, execFileResult } from "std/process";
import { ensureDir, exists, writeFile } from "std/fs";

const root = cwd();
const compilerEnv = env.get("MSC");
const compiler = compilerEnv != "" ? compilerEnv : `${root}/msc`;
const dir = `${root}/out/guardBareWasmUnowned`;
if (!ensureDir(dir).ok) throw new Error(`cannot create ${dir}`);

function build(name: string): string {
	const binary = `${dir}/${name}.wasm`;
	const built = execFileResult(compiler, [
		"build", `${root}/src/test/guard/fixtures/${name}.ms`,
		"--os=bare", "--cpu=wasm32", "--app=lib", "--release",
		`--output=${binary}`,
		"--passL=-Wl,--export=MsMain,--max-memory=1048576,--initial-memory=262144 -Wl,-z,stack-size=65536",
	], root);
	if (!writeFile(`${dir}/${name}.build.log`, built.output + built.errorOutput).ok) throw new Error(`cannot save the ${name} build log`);
	if (!built.started || !built.pipeOk || built.exitCode != 0 || built.signal != 0 || !exists(binary)) {
		throw new Error(`bare Wasm ${name} build failed: ${built.output}${built.errorOutput}`);
	}
	return binary;
}

const host = `${dir}/run.cjs`;
const source = `const fs = require("node:fs");
const mod = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
const instance = new WebAssembly.Instance(mod, {});
try {
	instance.exports.MsMain();
	console.log("RAN");
} catch (e) {
	console.log(e instanceof WebAssembly.RuntimeError ? "TRAPPED " + e.message : "THREW " + e);
}
`;
if (!writeFile(host, source).ok) throw new Error(`cannot write ${host}`);

function run(name: string): string {
	const ran = execFileResult("node", [host, build(name)], root);
	if (!writeFile(`${dir}/${name}.run.log`, ran.output + ran.errorOutput).ok) throw new Error(`cannot save the ${name} run log`);
	if (!ran.started || !ran.pipeOk || ran.exitCode != 0 || ran.signal != 0) throw new Error(`bare Wasm ${name} host failed: ${ran.output}${ran.errorOutput}`);
	return ran.output.trim();
}

const deadRead = run("bareWasmUnownedDeadRead");
if (!deadRead.startsWith("TRAPPED")) throw new Error(`a read through a dead Unowned edge on wasm32 did not stop: ${deadRead}`);
const deadKept = run("bareWasmUnownedDeadKept");
if (deadKept != "RAN") throw new Error(`a dead Unowned edge nobody reads stopped wasm32: ${deadKept}`);
const husks = run("bareWasmUnownedHuskReturns");
if (husks != "RAN") throw new Error(`husks did not return on wasm32: ${husks}`);
console.log("GUARD-OK");
