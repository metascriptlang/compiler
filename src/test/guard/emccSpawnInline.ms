// spawn on --os=emcc runs on the spawning thread and prints what the native build prints
// INVARIANT: with no worker thread, every spawn takes the inline path (the reference's `res = fn`),
// so its future is complete before any await: sync await, async await, struct and string results,
// Promise.all over spawns (sync and async), a nested spawn and a failing spawn all match native C.
// RED MEANS the emcc build does not link spawn (pool.c / awaitGroup.c missing there), or an inline
// completion overwrote the stored result (async await of a spawn read 0).
// It prints GUARD-SKIP without emcc or node on PATH.

import { execFileResult, cmdExists, cwd, env, exit } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : root + "/msc";
const fixture = root + "/src/test/guard/fixtures/emccSpawn.ms";
const nativeBin = root + "/out/guardEmccSpawn/emccSpawn";
const bundle = root + "/out/guardEmccSpawn/emccSpawn.js";

function fail(why: string): void {
	console.log("GUARD-FAIL " + why);
	exit(1);
}

if (!cmdExists("emcc") || !cmdExists("node")) {
	console.log("GUARD-SKIP emcc or node not on PATH");
	exit(0);
}

function run(path: string, args: string[]): string {
	const r = execFileResult(path, args);
	if (r.exitCode != 0) fail(`${path} ${args.join(" ")} exited ${r.exitCode}\n${r.output}${r.errorOutput}`);
	return r.output;
}

run(msc, ["build", fixture, "--output=" + nativeBin]);
const native = run(nativeBin, []);
run(msc, ["build", fixture, "--os=emcc", "--output=" + bundle]);
const emcc = run("node", [bundle]);
if (emcc.trim() != native.trim()) fail(`emcc printed\n${emcc}native printed\n${native}`);
console.log("GUARD-OK");
