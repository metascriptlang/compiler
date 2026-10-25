// guard: a deep Readonly module const crosses threads only when nothing a task calls on it can write
// a cell: a C extern reached from a call that reads the const, through a method receiver or a free
// call, directly or through a routine with a body, refuses the const on C and JS; a string length
// and == read of the const are accepted.
//
// WHY A SUBPROCESS: the accepted case is a claim that check stays silent.
//
// RED MEANS: a task reaches a C extern that may write a static through the const's read path and
//   still compiles, or a plain read of the const is refused.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const MODULE_STATE_RULE = "module state crosses threads only as";
const WRITES = "which may write state the checker cannot see";

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
	refused: boolean;
	text: string;
}

const CELL = "class Cell { n: int32 = 7; }\nconst K: Readonly<Cell> = new Cell();\n";
const BUMP = "extern function msBumpReadCount(): int32;\n";
const RUN = "const f = spawn(() => read());\nconsole.log(await f);\n";

const cases: Case[] = [
	{
		name: "a method with a body that calls a C extern",
		refused: true,
		text: CELL + BUMP
			+ "function peek(this c: Readonly<Cell>): int32 { return c.n + msBumpReadCount(); }\n"
			+ "function read(): int32 { return K.peek(); }\n" + RUN,
	},
	{
		name: "a free routine with a body that calls a C extern",
		refused: true,
		text: CELL + BUMP
			+ "function peekOf(c: Readonly<Cell>): int32 { return c.n + msBumpReadCount(); }\n"
			+ "function read(): int32 { return peekOf(K); }\n" + RUN,
	},
	{
		name: "a C extern called on the const as its receiver",
		refused: true,
		text: CELL
			+ "extern function bump(this c: Readonly<Cell>): int32;\n"
			+ "function read(): int32 { return K.bump(); }\n" + RUN,
	},
	{
		name: "a C extern called with the const as an argument",
		refused: true,
		text: CELL
			+ "extern function bumpOf(c: Readonly<Cell>): int32;\n"
			+ "function read(): int32 { return bumpOf(K); }\n" + RUN,
	},
	{
		name: "a string length and == read of the const",
		refused: false,
		text: "class Table { tag: string = \"t\" + \"ag\"; }\n"
			+ "const K: Readonly<Table> = new Table();\n"
			+ "function read(): int32 { return (K.tag == \"tag\" ? 1 : 0) + K.tag.length; }\n" + RUN,
	},
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/readonlyConstReadPathWritesNothing/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, c.text);
	for (const target of ["c", "js"]) {
		const r = execFileResult(msc, ["check", `--target=${target}`, `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		const name = `${c.name} [${target}]`;
		if (c.refused && (r.exitCode == 0 || !out.includes(WRITES) || !out.includes(MODULE_STATE_RULE))) report(`${name}: not refused: ${out}`);
		if (!c.refused && r.exitCode != 0) report(`${name}: check failed: ${out}`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
