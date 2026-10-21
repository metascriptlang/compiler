// guard: a spawn task that owns a value whose onDestroy/onCopy/onClone touches module state is
// reported like a task that touches it directly (ownedValueHookEffect, effects.ms).
//
// WHY A SUBPROCESS: it claims the diagnostic text only, not its level, so it holds after the spawn
//   rule turns from a warning into an error; GUARD-CHECK-FAIL would claim the level too.
//
// RED MEANS: a hooked task passed silently (the first case races on the shared array: ASan
//   reports a double-free or a heap overflow), or a neighbour without such a hook was reported.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const SPAWN_RULE = "spawn runs this thunk on another thread";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

interface Case {
	name: string;
	text: string;
	claims: string[];
}

const cases: Case[] = [];

function reported(name: string, claims: string[], text: string): void {
	cases.push({ name, text, claims });
}

function silent(name: string, text: string): void {
	cases.push({ name, text, claims: [] });
}

const box = "class Box { v: int32 = 0; }\nconst log: string[] = [];\nfunction onDestroy(this b: Box): void { log.push(\"x\"); }\n";

reported("a helper the thunk calls creates the hooked value", [
	"it calls 'work' at 6:", "which owns a 'Box' whose 'onDestroy' runs here at 4:", "which uses module-level 'log' at 3:",
], box
	+ "function work(i: int32): int32 { const b = new Box(); b.v = i; return b.v; }\n"
	+ "async function main(): Promise<void> {\n"
	+ "\tconst h1 = spawn(() => { let s: int32 = 0; for (let i: int32 = 0; i < 2000; i += 1) s += work(i); return s; });\n"
	+ "\tconst h2 = spawn(() => { let s: int32 = 0; for (let i: int32 = 0; i < 2000; i += 1) s += work(i); return s; });\n"
	+ "\tawait h1; await h2;\n\tconsole.log(`log=${log.length}`);\n}\nawait main();\n");

reported("the thunk creates the hooked value itself", [
	"it owns a 'Box' whose 'onDestroy' runs here at 5:", "which uses module-level 'log' at 3:",
], box
	+ "async function main(): Promise<void> {\n"
	+ "\tconst h = spawn(() => { const b = new Box(); b.v = 7; return b.v; });\n"
	+ "\tconsole.log(`${await h} ${log.length}`);\n}\nawait main();\n");

reported("a helper returns the hooked value to the routine the thunk calls", [
	"it calls 'work' at 7:", "which calls 'mk' at 5:", "which owns a 'Box' whose 'onDestroy' runs here at 4:", "which uses module-level 'log' at 3:",
], "class Box { v: int32; constructor(v: int32) { this.v = v; } }\nconst log: string[] = [];\n"
	+ "function onDestroy(this x: Box): void { log.push(\"d\"); }\n"
	+ "function mk(i: int32): Box { return new Box(i); }\nfunction work(i: int32): int32 { return mk(i).v; }\n"
	+ "async function main(): Promise<void> {\n\tconst h = spawn(() => work(4));\n"
	+ "\tconsole.log(`${await h} ${log.length}`);\n}\nawait main();\n");

reported("an onCopy hook of a struct the thunk receives from a call", [
	"it owns a 'Cell' whose 'onCopy' runs here at 6:", "which uses module-level 'log' at 3:",
], "struct Cell { n: int32; }\nconst log: string[] = [];\n"
	+ "function onCopy(this ref d: Cell, src: Cell): void { d.n = src.n; log.push(\"c\"); }\n"
	+ "function mk(i: int32): Cell { return { n: i }; }\n"
	+ "async function main(): Promise<void> {\n"
	+ "\tconst h = spawn(() => { const a = mk(3); const b = a; return a.n + b.n; });\n"
	+ "\tconsole.log(`${await h} ${log.length}`);\n}\nawait main();\n");

silent("a hook that writes only its own object and a local",
	"class Box { v: int32; constructor(v: int32) { this.v = v; } }\n"
	+ "function onDestroy(this x: Box): void { x.v = 0; let k: int32 = 1; k += x.v; }\n"
	+ "function work(i: int32): int32 { const b = new Box(i); return b.v; }\n"
	+ "async function main(): Promise<void> {\n\tconst h = spawn(() => work(5));\n\tconsole.log(`${await h}`);\n}\nawait main();\n");

silent("a thunk that creates no hooked value", box
	+ "function work(i: int32): int32 { return i * 2; }\n"
	+ "async function main(): Promise<void> {\n\tconst keep = new Box();\n\tconst h = spawn(() => work(6));\n"
	+ "\tconsole.log(`${await h} ${keep.v} ${log.length}`);\n}\nawait main();\n");

function checkOutput(dir: string, target: string): string {
	const args = target == "c" ? ["check", `${dir}/main.ms`] : ["check", `${dir}/main.ms`, "--target=js"];
	const r = execFileResult(msc, args);
	return `${r.exitCode == 0 ? "OK" : "ERR"}\n${r.output}${r.errorOutput}`;
}

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/spawnOwnedHookState/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, c.text);
	for (const target of ["c", "js"]) {
		const out = checkOutput(dir, target);
		if (c.claims.length == 0) {
			if (!out.startsWith("OK\n") || out.includes(SPAWN_RULE)) report(`[${target}] ${c.name}: reported: ${out}`);
			continue;
		}
		if (!out.includes(SPAWN_RULE)) {
			report(`[${target}] ${c.name}: not reported: ${out}`);
			continue;
		}
		for (const claim of c.claims) {
			if (!out.includes(claim)) report(`[${target}] ${c.name}: the report does not say '${claim}': ${out}`);
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
