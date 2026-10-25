// guard: a deep Readonly module const crosses threads only when no task can start before its
// initializer runs: a `spawn` or an actor started by module top-level code before the declaration,
// directly or through a callee, or by any top-level code of a module in its import cycle, refuses
// it on C and JS; a spawn after the declaration, or in a module that imports it without a cycle,
// is accepted.
//
// WHY A SUBPROCESS: the accepted cases are a claim that check stays silent, and the cycle cases
//   need several modules.
//
// RED MEANS: a task that can read the const's slot before it is initialised compiles (TSan
//   reported 3 races on the slot of the top-level case), or the init-order rule refuses a const
//   every task starts after.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const MODULE_STATE_RULE = "module state crosses threads only as";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

interface Source {
	file: string;
	text: string;
}

interface Case {
	name: string;
	refused: boolean;
	sources: Source[];
}

const CELL = "class Cell { n: int32 = 7; }\n";
const READ = "export function read(): int32 { let s = 0; for (let i = 0; i < 1000; i += 1) s += K.n; return s; }\n";

const cases: Case[] = [
	{
		name: "a top-level spawn before the declaration",
		refused: true,
		sources: [{ file: "main.ms", text: CELL + READ
			+ "const f = spawn(() => read());\n"
			+ "const K: Readonly<Cell> = new Cell();\n"
			+ "console.log(await f);\n" }],
	},
	{
		name: "a top-level call of a routine that spawns, before the declaration",
		refused: true,
		sources: [{ file: "main.ms", text: CELL + READ
			+ "function start(): Promise<int32> { return spawn(() => read()); }\n"
			+ "const f = start();\n"
			+ "const K: Readonly<Cell> = new Cell();\n"
			+ "console.log(await f);\n" }],
	},
	{
		name: "an actor started before the declaration",
		refused: true,
		sources: [{ file: "main.ms", text: CELL + READ
			+ "actor Reader { total(): int32 { return read(); } }\n"
			+ "const r = new Reader();\n"
			+ "const K: Readonly<Cell> = new Cell();\n"
			+ "const f = spawn(() => read());\n"
			+ "console.log(await f, await r.total());\n" }],
	},
	{
		name: "a top-level spawn in a module of the const's import cycle",
		refused: true,
		sources: [
			{ file: "main.ms", text: "import { early } from \"./other\";\n" + CELL + READ
				+ "export const K: Readonly<Cell> = new Cell();\n"
				+ "const f = spawn(() => read());\n"
				+ "console.log(await f, await early);\n" },
			{ file: "other.ms", text: "import { read } from \"./main\";\n"
				+ "export const early = spawn(() => read());\n" },
		],
	},
	{
		name: "a top-level spawn after the declaration",
		refused: false,
		sources: [{ file: "main.ms", text: CELL + READ
			+ "const K: Readonly<Cell> = new Cell();\n"
			+ "const f = spawn(() => read());\n"
			+ "console.log(await f);\n" }],
	},
	{
		name: "a top-level spawn in a module that imports the const without a cycle",
		refused: false,
		sources: [
			{ file: "main.ms", text: "import { read } from \"./cell\";\n"
				+ "const f = spawn(() => read());\n"
				+ "console.log(await f);\n" },
			{ file: "cell.ms", text: CELL + READ
				+ "export const K: Readonly<Cell> = new Cell();\n" },
		],
	},
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/readonlyConstInitBeforeTasks/${slot}`;
	ensureDir(dir);
	for (const s of c.sources) writeFile(`${dir}/${s.file}`, s.text);
	for (const target of ["c", "js"]) {
		const r = execFileResult(msc, ["check", `--target=${target}`, `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		const name = `${c.name} [${target}]`;
		if (c.refused && (r.exitCode == 0 || !out.includes(MODULE_STATE_RULE))) report(`${name}: not refused: ${out}`);
		if (!c.refused && r.exitCode != 0) report(`${name}: check failed: ${out}`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
