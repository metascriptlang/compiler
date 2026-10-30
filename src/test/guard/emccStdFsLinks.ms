// std/fs links on --os=emcc and prints what the native build prints
// INVARIANT: readFile and exists reach the posix file system runtime on emcc and wasm, so a program
// that imports std/fs builds, links and answers a missing file the way the native build does.
// RED MEANS the emcc link leaves the posix file system runtime out (undefined msFs symbols at link).
// It prints GUARD-SKIP without emcc or node on PATH.

import { execFileResult, cmdExists, cwd, env, exit } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : root + "/msc";
const fixture = root + "/src/test/guard/fixtures/emccStdFs.ms";
const nativeBin = root + "/out/guardEmccStdFs/emccStdFs";
const bundle = root + "/out/guardEmccStdFs/emccStdFs.js";

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
if (native.trim() != "not read\nabsent") fail(`native printed\n${native}`);
console.log("GUARD-OK");
