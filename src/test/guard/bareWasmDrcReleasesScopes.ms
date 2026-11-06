// A freestanding Wasm build defaults to DRC: 4096 scoped blocks of over 1 KiB each run their onDestroy
// and fit a 1 MiB memory only because each block returns to the heap. The module imports nothing.
// RED MEANS bare Wasm is manual again (the blocks exhaust memory and MsMain traps) or DRC pulls an import.
import { cwd, env, execFileResult } from "std/process";
import { ensureDir, exists, writeFile } from "std/fs";

const root = cwd();
const compilerEnv = env.get("MSC");
const compiler = compilerEnv != "" ? compilerEnv : `${root}/msc`;
const dir = `${root}/out/guardBareWasmDrc`;
if (!ensureDir(dir).ok) throw new Error(`cannot create ${dir}`);
const binary = `${dir}/drc.wasm`;
const built = execFileResult(compiler, [
	"build", `${root}/src/test/guard/fixtures/bareWasmDrcReuse.ms`,
	"--os=bare", "--cpu=wasm32", "--app=lib", "--release",
	`--output=${binary}`,
	"--passL=-Wl,--export=MsMain,--max-memory=1048576,--initial-memory=262144 -Wl,-z,stack-size=65536",
], root);
if (!writeFile(`${dir}/build.log`, built.output + built.errorOutput).ok) {
	throw new Error("cannot save bare Wasm DRC build log");
}
if (!built.started || !built.pipeOk || built.exitCode != 0 ||
	built.signal != 0 || !exists(binary)) {
	throw new Error(`bare Wasm DRC build failed: ${built.output}${built.errorOutput}`);
}
const host = `${dir}/run.cjs`;
const source = `const fs = require("node:fs");
const assert = require("node:assert/strict");
const mod = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
assert.deepEqual(WebAssembly.Module.imports(mod), []);
const instance = new WebAssembly.Instance(mod, {});
instance.exports.MsMain();
assert.ok(instance.exports.memory.buffer.byteLength <= 1048576);
console.log("WASM-DRC-OK");
`;
if (!writeFile(host, source).ok) throw new Error(`cannot write ${host}`);
const ran = execFileResult("node", [host, binary], root);
if (!writeFile(`${dir}/run.log`, ran.output + ran.errorOutput).ok) {
	throw new Error("cannot save bare Wasm DRC execution log");
}
if (!ran.started || !ran.pipeOk || ran.exitCode != 0 || ran.signal != 0 ||
	ran.output.trim() != "WASM-DRC-OK") {
	throw new Error(`bare Wasm DRC run failed: ${ran.output}${ran.errorOutput}`);
}
console.log("GUARD-OK");
