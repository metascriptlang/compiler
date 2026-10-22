// guard: the effect walk over a call cycle costs about one walk per routine, not one per path.
//
// INVARIANT: a routine found pure only while a routine on the stack is assumed pure is answered
//   from the memo for the rest of that walk, and becomes pure when the outermost routine does
//   (memo in effects.ms). Without it, every routine on a cycle is walked again at each call, so a
//   chain of N routines that each call the next twice costs 2^N walks.
//
// WHY A SUBPROCESS AND A RATIO: the guard runner has no per-probe timeout, and the observable is
//   the cost of `msc check`. Each shape is timed against the same call graph without a spawn,
//   which skips the spawn effect walk; a ratio stays meaningful on a loaded host.
//   Measured 2026-10-22 (user s, control → fixed): free functions N=14 236 → 1.9,
//   methods N=12 21 → 1.9, same graphs without spawn 1.9.
//
// RED MEANS: the spawn effect walk re-walks the routines of a cycle again (the check of a shape
//   took more than RATIO times its no-spawn twin plus SLACK_MS).

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const RATIO = 5.0;
const SLACK_MS = 20000.0;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

function freeFunctions(n: int32, entry: string): string {
	let src = "";
	for (let i: int32 = 0; i < n; i += 1) {
		const next = i < n - 1 ? `f${i + 1}(k - 1) + f${i + 1}(k - 2)` : "f0(k - 1)";
		src += `function f${i}(k: int32): int32 { if (k <= 0) return 1; return ${next}; }\n`;
	}
	return src + entry.replaceAll("CALL", "f0(3)");
}

function methods(n: int32, entry: string): string {
	let src = "class Walker {\n";
	for (let i: int32 = 0; i < n; i += 1) {
		const next = i < n - 1 ? `this.m${i + 1}(k - 1) + this.m${i + 1}(k - 2)` : "this.m0(k - 1)";
		src += `\tm${i}(k: int32): int32 { if (k <= 0) return 1; return ${next}; }\n`;
	}
	return src + "}\n" + entry.replaceAll("CALL", "new Walker().m0(3)");
}

const SPAWNED = "const h = spawn(() => CALL);\nconsole.log(`${await h}`);\n";
const DIRECT = "console.log(`${CALL}`);\n";

function timedCheck(dir: string, name: string, text: string): float64 {
	writeFile(`${dir}/${name}.ms`, text);
	const t0 = performance.now();
	const r = execFileResult(msc, ["check", `${dir}/${name}.ms`]);
	const ms = performance.now() - t0;
	if (r.exitCode != 0) report(`${name}: check failed: ${r.output}${r.errorOutput}`);
	return ms;
}

function shape(dir: string, name: string, spawned: string, direct: string): void {
	const base = timedCheck(dir, `${name}Direct`, direct);
	const walked = timedCheck(dir, `${name}Spawned`, spawned);
	console.log(`${name}: ${walked as int64} ms spawned, ${base as int64} ms direct`);
	if (walked > base * RATIO + SLACK_MS) report(`${name}: the spawned check took ${walked as int64} ms against ${base as int64} ms without the spawn`);
}

const dir = `${root}/out/guard/effectWalkCycleCost`;
ensureDir(dir);
shape(dir, "freeFunctions", freeFunctions(14, SPAWNED), freeFunctions(14, DIRECT));
shape(dir, "methods", methods(13, SPAWNED), methods(13, DIRECT));

if (failed != 0) exit(1);
console.log("GUARD-OK");
