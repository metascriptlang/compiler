import { cwd, env, execFileResult } from "std/process";
import { ensureDir, exists, writeFile } from "std/fs";

const root = cwd();
const compilerEnv = env.get("MSC");
const compiler = compilerEnv != "" ? compilerEnv : `${root}/msc`;
const dir = `${root}/out/guardBareWasmReuse`;
if (!ensureDir(dir).ok) throw new Error(`cannot create ${dir}`);
const binary = `${dir}/reuse.wasm`;
const built = execFileResult(compiler, [
	"build", `${root}/src/test/guard/fixtures/bareWasmReuse.ms`,
	"--os=bare", "--cpu=wasm32", "--app=lib", "--release",
	`--output=${binary}`,
	"--passL=-Wl,--export=MsMain,--max-memory=1048576,--initial-memory=262144 -Wl,-z,stack-size=65536",
], root);
if (!writeFile(`${dir}/build.log`, built.output + built.errorOutput).ok) {
	throw new Error("cannot save bare Wasm build log");
}
if (!built.started || !built.pipeOk || built.exitCode != 0 ||
	built.signal != 0 || !exists(binary)) {
	throw new Error(`bare Wasm build failed: ${built.output}${built.errorOutput}`);
}
const rejected = execFileResult(compiler, [
	"build", `${root}/src/test/guard/fixtures/bareWasmReuse.ms`,
	"--os=bare", "--cpu=wasm32", "--app=lib", "--release",
	`--output=${dir}/recursive.wasm`, "--passC=-DMS_HEAP_USE_MALLOC=1",
], root);
const rejection = rejected.output + rejected.errorOutput;
if (!writeFile(`${dir}/recursive.build.log`, rejection).ok) {
	throw new Error("cannot save recursive heap rejection log");
}
if (!rejected.started || !rejected.pipeOk || rejected.exitCode == 0 ||
	!rejection.includes("freestanding libc requires the custom heap backend")) {
	throw new Error(`recursive freestanding heap was not refused: ${rejection}`);
}
const host = `${dir}/run.cjs`;
const source = `const fs = require("node:fs");
const assert = require("node:assert/strict");
const mod = new WebAssembly.Module(fs.readFileSync(process.argv[2]));
assert.deepEqual(WebAssembly.Module.imports(mod), []);
const instance = new WebAssembly.Instance(mod, {});
assert.equal(typeof instance.exports.MsMain, "function");
assert.ok(instance.exports.memory instanceof WebAssembly.Memory);
const min = -(1n << 63n), max = (1n << 63n) - 1n;
const cases = [[17n,19n,323n,0],[-3n,7n,-21n,0],[max,1n,max,0],
[max,2n,0n,1],[min,-1n,0n,1],[0n,min,0n,0],[-4294967296n,2147483648n,min,0]];
for (const args of cases) {
	assert.equal(instance.exports.checkedMultiply(...args), 0);
}
const isolated = new WebAssembly.Instance(mod, {});
assert.equal(isolated.exports.libcContracts(), 0, "libc allocation family");
instance.exports.MsMain();
assert.ok(instance.exports.memory.buffer.byteLength <= 1048576);
console.log("WASM-HEAP-OK");
`;
if (!writeFile(host, source).ok) throw new Error(`cannot write ${host}`);
const ran = execFileResult("node", [host, binary], root);
if (!writeFile(`${dir}/run.log`, ran.output + ran.errorOutput).ok) {
	throw new Error("cannot save bare Wasm execution log");
}
if (!ran.started || !ran.pipeOk || ran.exitCode != 0 || ran.signal != 0 ||
	ran.output.trim() != "WASM-HEAP-OK") {
	throw new Error(`bare Wasm reuse failed: ${ran.output}${ran.errorOutput}`);
}
console.log("GUARD-OK");
