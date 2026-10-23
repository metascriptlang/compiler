// guard: a module `const` crosses threads when its declared type is deep Readonly and its value is
// built in its own initializer; a module `let`, or a Readonly const that names a value another
// binding holds, is refused, and a write through an alias of the const is refused.
//
// WHY A SUBPROCESS: the accepted case is a claim that check stays silent; GUARD-CHECK-FAIL can
//   only claim an error.
//
// RED MEANS: the spawn rule stopped telling an immutable built-in-place const from shared mutable
//   state, or the Readonly view stopped refusing a write through an alias.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const MODULE_STATE_RULE = "module state crosses threads only as";
const WRITE_RULE = "cannot write through Readonly";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

enum Expect { Clean, ModuleState, WriteRefused }

interface Case {
	name: string;
	expect: Expect;
	text: string;
}

const CELL = "interface Cell { n: int32; tag: string; }\n"
	+ "function build(n: int32): Cell { return { n: n, tag: \"t\" }; }\n";
const SPAWN = "function main(): void {\n"
	+ "\tconst f = spawn(() => read());\n"
	+ "\tconsole.log(await f);\n"
	+ "}\n"
	+ "main();\n";

const cases: Case[] = [
	{
		name: "Readonly consts built by a literal and by a call",
		expect: Expect.Clean,
		text: CELL
			+ "const lit: Readonly<Cell> = { n: 1, tag: \"a\" };\n"
			+ "const made: Readonly<Cell> = build(2);\n"
			+ "const list: Readonly<Cell[]> = [build(3), { n: 4, tag: \"b\" }];\n"
			+ "function read(): int32 { return lit.n + made.n + list[1].n; }\n"
			+ SPAWN,
	},
	{
		name: "a module let",
		expect: Expect.ModuleState,
		text: CELL
			+ "let cell: Cell = build(1);\n"
			+ "function read(): int32 { return cell.n; }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const that names a value a mutable binding holds",
		expect: Expect.ModuleState,
		text: CELL
			+ "const owner: Cell = build(1);\n"
			+ "const view: Readonly<Cell> = owner;\n"
			+ "function read(): int32 { return view.n; }\n"
			+ SPAWN,
	},
	{
		name: "a write through an alias of a Readonly const",
		expect: Expect.WriteRefused,
		text: CELL
			+ "const lit: Readonly<Cell> = { n: 1, tag: \"a\" };\n"
			+ "function poke(): void { const alias = lit; alias.n = 2; }\n"
			+ "poke();\n",
	},
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/readonlyConstCrossesThreads/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, c.text);
	const r = execFileResult(msc, ["check", `${dir}/main.ms`]);
	const out = `${r.output}${r.errorOutput}`;
	match (c.expect) {
		Expect.Clean => {
			if (r.exitCode != 0) report(`${c.name}: check failed: ${out}`);
			else if (out.includes(MODULE_STATE_RULE)) report(`${c.name}: module state reported: ${out}`);
		},
		Expect.ModuleState => {
			if (r.exitCode == 0 || !out.includes(MODULE_STATE_RULE)) report(`${c.name}: module state not refused: ${out}`);
		},
		Expect.WriteRefused => {
			if (r.exitCode == 0 || !out.includes(WRITE_RULE)) report(`${c.name}: write not refused: ${out}`);
		},
	};
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
