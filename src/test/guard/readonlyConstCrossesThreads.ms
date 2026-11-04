// guard: a module `const` crosses threads when its declared type is deep Readonly and its value is
// built in its own initializer, or when the const rule keeps its type unwritable through every path
// (a declared struct of scalars, strings, Vec and Sendable functions); a module `let`, a const of a
// class or of a struct with a T[], tuple, interface or plain function field, a Readonly const that names a value another
// binding holds, or one returned by a call on a receiver that is not fresh (a method, an extension
// or a chained receiver that may keep the result), is refused on C and JS, and a write through an
// alias of the const, a cast, a non-null assertion, an alias of its type or an `out` argument is refused.
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
const CAPTURE_RULE = "cannot be captured by a Sendable function";
const CONST_RULE = "is const (use 'let')";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

enum Expect { Clean, ModuleState, CaptureRefused, WriteRefused, ConstWriteRefused }

interface Case {
	name: string;
	expect: Expect;
	text: string;
}

const CELL = "interface Cell { n: int32; tag: string; }\n"
	+ "function build(n: int32): Cell { return { n: n, tag: \"t\" }; }\n";
const TABLE = CELL
	+ "struct Table { name: string; keyOf: Sendable<(c: Cell) => int32>; }\n"
	+ "function table(name: string, keyOf: Sendable<(c: Cell) => int32>): Table { return { name, keyOf }; }\n";
const GENERIC = "struct Account { id: string; }\n"
	+ "struct Table<T> { name: string; columns: Vec<string>; }\n"
	+ "struct Rows<T> { name: string; rows: Vec<T>; }\n"
	+ "type Either<T> = { kind: \"a\"; v: Vec<string> } | { kind: \"b\"; w: T };\n";
const GENERIC_CALL = "struct Keyed<T> { name: string; keyOf: Sendable<(row: T) => int32>; }\n"
	+ "function keyed<T>(name: string, keyOf: Sendable<(row: T) => int32>): Keyed<T> { return { name: name, keyOf: keyOf }; }\n";
const SPAWN = "async function main(): Promise<void> {\n"
	+ "\tconst f = spawn(() => read());\n"
	+ "\tconsole.log(await f);\n"
	+ "}\n"
	+ "await main();\n";
const FACTORY = "class Factory {\n"
	+ "\tcache: Cell[] = [];\n"
	+ "\tmake(n: int32): Cell { const c = build(n); this.cache.push(c); return c; }\n"
	+ "}\n"
	+ "function keep(this f: Factory, n: int32): Cell { const c = build(n); f.cache.push(c); return c; }\n"
	+ "class Outer { inner: Factory = new Factory(); }\n";

const PLAIN = "struct Table { name: string; columns: Vec<string>; keyOf: Sendable<(id: uint32) => uint32>; }\n"
	+ "function table(name: string, keyOf: Sendable<(id: uint32) => uint32>): Table { return { name: name, columns: [\"id\", \"balance\"], keyOf: keyOf }; }\n";
const ACTOR = "actor Runner {\n"
	+ "\tsource: Sendable<() => string>;\n"
	+ "\tconstructor(source: Sendable<() => string>) { this.source = source; }\n"
	+ "\trun(): string { return this.source(); }\n"
	+ "}\n"
	+ "const runner = new Runner((): string => read());\n"
	+ "console.log(await runner.run());\n";

const cases: Case[] = [
	{
		name: "a plain const struct of strings, a Vec and a Sendable function, read from a spawn",
		expect: Expect.Clean,
		text: PLAIN
			+ "const accounts = table(\"accounts\", (id: uint32): uint32 => id + 1);\n"
			+ "function read(): string { return accounts.name + String(accounts.columns.length) + String(accounts.keyOf(1)); }\n"
			+ SPAWN,
	},
	{
		name: "a plain const struct of strings, a Vec and a Sendable function, read from an actor",
		expect: Expect.Clean,
		text: PLAIN
			+ "const accounts = table(\"accounts\", (id: uint32): uint32 => id + 1);\n"
			+ "function read(): string { return accounts.name + String(accounts.columns.length) + String(accounts.keyOf(1)); }\n"
			+ ACTOR,
	},
	{
		name: "a plain const of a generic struct instance with a Vec<T> field",
		expect: Expect.Clean,
		text: GENERIC
			+ "const r: Rows<Account> = { name: \"r\", rows: [{ id: \"1\" }] };\n"
			+ "function read(): string { return r.name + r.rows[0].id; }\n"
			+ SPAWN,
	},
	{
		name: "a module let struct read from an actor",
		expect: Expect.ModuleState,
		text: PLAIN
			+ "let accounts = table(\"accounts\", (id: uint32): uint32 => id + 1);\n"
			+ "function read(): string { return accounts.name; }\n"
			+ ACTOR,
	},
	{
		name: "a const holding a class instance",
		expect: Expect.ModuleState,
		text: CELL + FACTORY
			+ "const F: Factory = new Factory();\n"
			+ "function read(): int32 { return F.cache.length; }\n"
			+ SPAWN,
	},
	{
		name: "a const struct with a T[] field, writable through the const",
		expect: Expect.ModuleState,
		text: "struct Tagged { name: string; tags: string[]; }\n"
			+ "const h: Tagged = { name: \"h\", tags: [\"t\"] };\n"
			+ "function read(): int32 { return h.tags.length; }\n"
			+ SPAWN,
	},
	{
		name: "a const struct with a tuple field, writable through the const",
		expect: Expect.ModuleState,
		text: "struct Paired { name: string; pair: [int32, string]; }\n"
			+ "const h: Paired = { name: \"h\", pair: [1, \"p\"] };\n"
			+ "function read(): string { return h.pair[1]; }\n"
			+ SPAWN,
	},
	{
		name: "a const struct with a plain function field",
		expect: Expect.ModuleState,
		text: "struct Hooked { name: string; f: () => int32; }\n"
			+ "const h: Hooked = { name: \"h\", f: (): int32 => 1 };\n"
			+ "function read(): string { return h.name; }\n"
			+ SPAWN,
	},
	{
		name: "a const struct with an interface field, writable through the const",
		expect: Expect.ModuleState,
		text: CELL
			+ "struct Wrap { name: string; cell: Cell; }\n"
			+ "const h: Wrap = { name: \"h\", cell: build(1) };\n"
			+ "function read(): string { return h.name; }\n"
			+ SPAWN,
	},
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
		name: "a Readonly const a fresh receiver's method returns",
		expect: Expect.Clean,
		text: CELL + FACTORY
			+ "const made: Readonly<Cell> = new Factory().make(1);\n"
			+ "function read(): int32 { return made.n; }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const a module const's method caches",
		expect: Expect.ModuleState,
		text: CELL + FACTORY
			+ "const F: Factory = new Factory();\n"
			+ "const made: Readonly<Cell> = F.make(1);\n"
			+ "function read(): int32 { return made.n; }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const array holding what a module const's method caches",
		expect: Expect.ModuleState,
		text: CELL + FACTORY
			+ "const F: Factory = new Factory();\n"
			+ "const list: Readonly<Cell[]> = [build(1), F.make(2)];\n"
			+ "function read(): int32 { return list[1].n; }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const an extension on a module const caches",
		expect: Expect.ModuleState,
		text: CELL + FACTORY
			+ "const F: Factory = new Factory();\n"
			+ "const made: Readonly<Cell> = F.keep(1);\n"
			+ "function read(): int32 { return made.n; }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const a chained receiver's method caches",
		expect: Expect.ModuleState,
		text: CELL + FACTORY
			+ "const F: Outer = new Outer();\n"
			+ "const made: Readonly<Cell> = F.inner.make(1);\n"
			+ "function read(): int32 { return made.n; }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const built by a call that takes a Sendable closure literal",
		expect: Expect.Clean,
		text: TABLE
			+ "const made: Readonly<Table> = table(\"t\", (c: Cell): int32 => c.n + 1);\n"
			+ "function read(): int32 { return made.keyOf(build(1)); }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const literal holding a Sendable function expression",
		expect: Expect.Clean,
		text: TABLE
			+ "const made: Readonly<Table> = { name: \"t\", keyOf: function (c: Cell): int32 { return c.n; } };\n"
			+ "function read(): int32 { return made.keyOf(build(1)); }\n"
			+ SPAWN,
	},
	{
		name: "a Sendable closure literal that captures a Readonly module const",
		expect: Expect.Clean,
		text: TABLE
			+ "const base: Readonly<int32[]> = [1];\n"
			+ "const made: Readonly<Table> = table(\"t\", (c: Cell): int32 => c.n + base[0]);\n"
			+ "function read(): int32 { return made.keyOf(build(1)); }\n"
			+ SPAWN,
	},
	{
		name: "a Sendable closure literal that captures a module let",
		expect: Expect.CaptureRefused,
		text: TABLE
			+ "let base: int32[] = [1];\n"
			+ "const made: Readonly<Table> = table(\"t\", (c: Cell): int32 => c.n + base[0]);\n"
			+ "function read(): int32 { return made.keyOf(build(1)); }\n"
			+ SPAWN,
	},
	{
		name: "a Sendable closure literal that reads a mutable class a module const holds",
		expect: Expect.ModuleState,
		text: TABLE + FACTORY
			+ "const F: Factory = new Factory();\n"
			+ "const made: Readonly<Table> = table(\"t\", (c: Cell): int32 => c.n + F.cache.length);\n"
			+ "function read(): int32 { return made.keyOf(build(1)); }\n"
			+ SPAWN,
	},
	{
		name: "a Readonly const holding a plain closure literal",
		expect: Expect.ModuleState,
		text: CELL
			+ "struct Plain { name: string; keyOf: (c: Cell) => int32; }\n"
			+ "function plain(name: string, keyOf: (c: Cell) => int32): Plain { return { name, keyOf }; }\n"
			+ "const made: Readonly<Plain> = plain(\"t\", (c: Cell): int32 => c.n);\n"
			+ "function read(): int32 { return made.name.length; }\n"
			+ SPAWN,
	},
	{
		name: "Readonly consts of generic instances: a struct, a Vec<T> field and a union",
		expect: Expect.Clean,
		text: GENERIC
			+ "const t: Readonly<Table<Account>> = { name: \"accounts\", columns: [\"id\"] };\n"
			+ "const r: Readonly<Rows<Account>> = { name: \"r\", rows: [{ id: \"1\" }] };\n"
			+ "const e: Readonly<Either<Account>> = { kind: \"a\", v: [\"x\"] };\n"
			+ "function read(): string { return t.name + String(t.columns.length) + r.rows[0].id + e.kind; }\n"
			+ SPAWN,
	},
	{
		name: "Readonly consts built by generic calls whose Sendable formal names the type parameter",
		expect: Expect.Clean,
		text: CELL + GENERIC_CALL
			+ "const made: Readonly<Keyed<Cell>> = keyed<Cell>(\"t\", (c: Cell): int32 => c.n + 1);\n"
			+ "const guessed: Readonly<Keyed<Cell>> = keyed(\"t\", (c: Cell): int32 => c.n);\n"
			+ "function read(): int32 { return made.keyOf(build(1)) + guessed.keyOf(build(2)); }\n"
			+ SPAWN,
	},
	{
		name: "a closure at a generic Sendable formal that captures a module let",
		expect: Expect.CaptureRefused,
		text: CELL + GENERIC_CALL
			+ "let base: int32[] = [1];\n"
			+ "const made: Readonly<Keyed<Cell>> = keyed<Cell>(\"t\", (c: Cell): int32 => c.n + base[0]);\n"
			+ "function read(): int32 { return made.keyOf(build(1)); }\n"
			+ SPAWN,
	},
	{
		name: "a write through a let alias of a Readonly const of a generic instance",
		expect: Expect.WriteRefused,
		text: GENERIC
			+ "const t: Readonly<Table<Account>> = { name: \"accounts\", columns: [\"id\"] };\n"
			+ "function poke(): void { let alias = t; alias.name = \"x\"; }\n"
			+ "poke();\n",
	},
	{
		name: "a write through an alias of a Readonly const",
		expect: Expect.WriteRefused,
		text: CELL
			+ "const lit: Readonly<Cell> = { n: 1, tag: \"a\" };\n"
			+ "function poke(): void { const alias = lit; alias.n = 2; }\n"
			+ "poke();\n",
	},
	{
		name: "a push into a plain const's Vec field through a cast",
		expect: Expect.ConstWriteRefused,
		text: "struct Table { name: string; columns: Vec<string>; }\n"
			+ "const T: Table = { name: \"a\", columns: [\"id\"] };\n"
			+ "(T as Table).columns.push(\"x\");\n",
	},
	{
		name: "a push into a nullable const's Vec field through a non-null assertion",
		expect: Expect.ConstWriteRefused,
		text: "struct Table { name: string; columns: Vec<string>; }\n"
			+ "function mk(): Table | null { return { name: \"a\", columns: [\"id\"] }; }\n"
			+ "const T: Table | null = mk();\n"
			+ "T!.columns.push(\"x\");\n",
	},
	{
		name: "a push into a const's Vec field when the const's type is an alias of the struct",
		expect: Expect.ConstWriteRefused,
		text: "struct Table { name: string; columns: Vec<string>; }\n"
			+ "type Alias = Table;\n"
			+ "const T: Alias = { name: \"a\", columns: [\"id\"] };\n"
			+ "T.columns.push(\"x\");\n",
	},
	{
		name: "a const's Vec field passed as an out argument",
		expect: Expect.ConstWriteRefused,
		text: "struct Table { name: string; columns: Vec<string>; }\n"
			+ "function refill(out v: Vec<string>): void { v = [\"p\"]; }\n"
			+ "const T: Table = { name: \"a\", columns: [\"id\"] };\n"
			+ "refill(out T.columns);\n",
	},
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/readonlyConstCrossesThreads/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, c.text);
	for (const target of ["c", "js"]) {
		const r = execFileResult(msc, ["check", `--target=${target}`, `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		const name = `${c.name} [${target}]`;
		match (c.expect) {
			Expect.Clean => {
				if (r.exitCode != 0) report(`${name}: check failed: ${out}`);
				else if (out.includes(MODULE_STATE_RULE)) report(`${name}: module state reported: ${out}`);
			},
			Expect.ModuleState => {
				if (r.exitCode == 0 || !out.includes(MODULE_STATE_RULE)) report(`${name}: module state not refused: ${out}`);
			},
			Expect.CaptureRefused => {
				if (r.exitCode == 0 || !out.includes(CAPTURE_RULE)) report(`${name}: mutable capture not refused: ${out}`);
			},
			Expect.WriteRefused => {
				if (r.exitCode == 0 || !out.includes(WRITE_RULE)) report(`${name}: write not refused: ${out}`);
			},
			Expect.ConstWriteRefused => {
				if (r.exitCode == 0 || !out.includes(CONST_RULE)) report(`${name}: write through the const not refused: ${out}`);
			},
		};
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
