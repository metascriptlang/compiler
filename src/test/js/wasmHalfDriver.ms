// buildWasmHalf builds a hand-written entry as the wasm half and the result runs under node.
// Needs emcc on PATH (on this Windows host: the emcc-shim environment from the lane card).

import { cwd, findOnPath, execFileResult } from "std/process";
import { writeFile, exists } from "std/fs";
import { buildWasmHalf } from "../../compiler/wasmBoundary/placementBuild";
import { newCliOptions } from "../../compiler/options";

const calcSource = `@exportName("calc_add64")
export function add64(a: int64, b: int64): int64 {
	return a + b;
}

@emit("__attribute__((import_module(\\"env\\"), import_name(\\"host_callback\\"))) int32_t host_callback(int32_t id, int32_t value);");
extern function host_callback(id: int32, value: int32): int32 from "host_callback";

@exportName("calc_evaluate")
export function evaluate(value: int32, callbackId: int32): int32 {
	return host_callback(callbackId, value) + 1;
}
`;

const hostLibrary = `addToLibrary({
  host_callback: (id, value) => globalThis.__msBoundary.call(id, value),
});
`;

const runner = `import factory from './calc.wasm.mjs';
const callbacks = [];
globalThis.__msBoundary = { call: (id, v) => callbacks[id](v) };
const mod = await factory();
mod._MsMain();
const evaluate = (v, cb) => { callbacks.push(cb); try { return mod._calc_evaluate(v, callbacks.length - 1); } finally { callbacks.pop(); } };
console.log(String(mod._calc_add64(9007199254740993n, 2n)));
console.log(evaluate(20, x => x * 2));
console.log(evaluate(1, x => evaluate(x, y => y - 6)));
`;

test "the wasm half of a hand-written entry builds and runs under node" {
	const dir = `${cwd()}/out/wasmHalfDriver`;
	const built = buildWasmHalf(calcSource, ["_calc_add64", "_calc_evaluate", "_MsMain"], [], hostLibrary, `${dir}/calc`, newCliOptions());
	if (!built.ok) assert built.error == "";
	assert exists(`${dir}/calc.wasm.mjs`);
	assert exists(`${dir}/calc.wasm`);
	assert writeFile(`${dir}/run.mjs`, runner).ok;
	const node = findOnPath("node");
	assert node != "";
	const ran = execFileResult(node, [`${dir}/run.mjs`], dir);
	assert ran.exitCode == 0;
	assert ran.output.replace("\r", "") == "9007199254740995\n41\n-3\n";
}
