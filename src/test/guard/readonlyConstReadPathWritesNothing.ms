// guard: a deep Readonly module const crosses threads when nothing a task or an actor hands it to
// can count or write it. Passing the const, or a parameter bound to it, to a C extern whose
// parameter is a counted handle refuses it on C and JS, whether the call is on the task's own line
// or inside a routine the const reaches, and an actor method that stores the const or passes it to
// such an extern is refused the same way; a string, scalar or Readonly view of value-only data
// passes (includes, indexOf, lastIndexOf), and so does an extern a helper calls with its own locals
// (a push into a fresh Vec), while a push into a module `let` stays refused as module state.
//
// WHY A SUBPROCESS: the accepted case is a claim that check stays silent.
//
// RED MEANS: C receives the const through a parameter that can count or write it and the program
//   still compiles, or a read or a local-only extern call on the const's path is refused.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const MODULE_STATE_RULE = "module state crosses threads only as";
const FOREIGN = "C may count or write what it receives there";

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
	mark?: string;
	rule?: string;
}

const CELL = "class Cell { n: int32 = 7; }\nconst K: Readonly<Cell> = new Cell();\n";
const BUMP = "extern function msBumpReadCount(): int32;\n";
const RUN = "const f = spawn(() => read());\nconsole.log(await f);\n";
const SHAPE = "struct Slice { offset: int32; }\nstruct Shape { slices: Vec<Slice>; }\n"
	+ "const shape: Readonly<Shape> = { slices: [{ offset: 1 }, { offset: 2 }] };\n";

const ACTOR_RUN = "const a = new Holder();\nconsole.log(await a.read());\n";
const BUMP_OF = "extern function bumpOf(c: Readonly<Cell>): int32;\n";

const cases: Case[] = [
	{
		name: "a method with a body that calls a C extern on its own locals",
		refused: false,
		text: CELL + BUMP
			+ "function peek(this c: Readonly<Cell>): int32 { return c.n + msBumpReadCount(); }\n"
			+ "function read(): int32 { return K.peek(); }\n" + RUN,
	},
	{
		name: "a free routine with a body that calls a C extern on its own locals",
		refused: false,
		text: CELL + BUMP
			+ "function peekOf(c: Readonly<Cell>): int32 { return c.n + msBumpReadCount(); }\n"
			+ "function read(): int32 { return peekOf(K); }\n" + RUN,
	},
	{
		name: "a C extern called on the const as its receiver",
		refused: true,
		mark: "to the external 'bump' through a parameter",
		rule: FOREIGN,
		text: CELL
			+ "extern function bump(this c: Readonly<Cell>): int32;\n"
			+ "function read(): int32 { return K.bump(); }\n" + RUN,
	},
	{
		name: "a C extern called with the const as an argument",
		refused: true,
		mark: "to the external 'bumpOf' through a parameter",
		rule: FOREIGN,
		text: CELL + BUMP_OF
			+ "function read(): int32 { return bumpOf(K); }\n" + RUN,
	},
	{
		name: "a C extern a routine calls with the parameter the const is bound to",
		refused: true,
		mark: "to the external 'bumpOf' through a parameter",
		rule: FOREIGN,
		text: CELL + BUMP_OF
			+ "function peekOf(c: Readonly<Cell>): int32 { return bumpOf(c); }\n"
			+ "function read(): int32 { return peekOf(K); }\n" + RUN,
	},
	{
		name: "a string length and == read of the const",
		refused: false,
		text: "class Table { tag: string = \"t\" + \"ag\"; }\n"
			+ "const K: Readonly<Table> = new Table();\n"
			+ "function read(): int32 { return (K.tag == \"tag\" ? 1 : 0) + K.tag.length; }\n" + RUN,
	},
	{
		name: "a push into a fresh local Vec of copies of the const's elements",
		refused: false,
		text: SHAPE
			+ "function copies(slices: Readonly<Vec<Slice>>): Vec<Slice> {\n"
			+ "\tlet out: Vec<Slice> = [];\n\tfor (const slice of slices) { out.push({ offset: slice.offset }); }\n\treturn out;\n}\n"
			+ "function read(): int32 { return copies(shape.slices).length; }\n" + RUN,
	},
	{
		name: "a push of a scalar into a fresh local inside a method on the const",
		refused: false,
		text: SHAPE
			+ "function firstOffset(this s: Readonly<Shape>): int32 { let out: Vec<int32> = []; out.push(s.slices[0].offset); return out[0]; }\n"
			+ "function read(): int32 { return shape.firstOffset(); }\n" + RUN,
	},
	{
		name: "a string[] includes on the const inside a routine a task calls",
		refused: false,
		text: "const known: Readonly<string[]> = [\"a\", \"b\"];\n"
			+ "function has(x: string): boolean { return known.includes(x); }\n"
			+ "function read(): int32 { return has(\"b\") ? 1 : 0; }\n" + RUN,
	},
	{
		name: "a number[] indexOf and string[] lastIndexOf called on the const directly",
		refused: false,
		text: "const nums: Readonly<number[]> = [1, 2];\nconst names: Readonly<string[]> = [\"a\", \"b\"];\n"
			+ "function read(): number { return nums.indexOf(2) + names.lastIndexOf(\"a\"); }\n" + RUN,
	},
	{
		name: "a push into a module let inside a routine that reads the const",
		refused: true,
		mark: "module-level 'kept'",
		rule: MODULE_STATE_RULE,
		text: SHAPE + "let kept: Vec<Slice> = [];\n"
			+ "function copies(slices: Readonly<Vec<Slice>>): int32 { for (const slice of slices) { kept.push({ offset: slice.offset }); } return 0; }\n"
			+ "function read(): int32 { return copies(shape.slices); }\n" + RUN,
	},
	{
		name: "an actor method that passes the const to a C extern",
		refused: true,
		mark: "to the external 'bumpOf' through a parameter",
		rule: FOREIGN,
		text: CELL + BUMP_OF
			+ "actor Holder { read(): int32 { return bumpOf(K); } }\n" + ACTOR_RUN,
	},
	{
		name: "an actor method that stores the const into a field",
		refused: true,
		mark: "stores the module const 'K' into a field",
		rule: "store an explicit copy of it",
		text: CELL
			+ "class Keep { held: Readonly<Cell> | null = null; }\n"
			+ "actor Holder { keep: Keep = new Keep(); read(): int32 { this.keep.held = K; return 1; } }\n" + ACTOR_RUN,
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
		if (c.refused && (r.exitCode == 0 || !out.includes(c.mark!) || !out.includes(c.rule!))) report(`${name}: not refused: ${out}`);
		if (!c.refused && r.exitCode != 0) report(`${name}: check failed: ${out}`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
