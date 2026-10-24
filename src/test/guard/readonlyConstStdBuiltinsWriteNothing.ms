// guard: a std builtin whose compiler-supplied body writes no cell (PtrBits, Float64Bits, HiXorLo,
// MapFatal) does not refuse a task reading a deep Readonly module const, while a user extern does,
// a user extern that claims one of those builtin kinds included. The builtins are declared only by
// the C std, so the accepted cases run on C and the refused ones on C and JS.
//
// WHY A SUBPROCESS: the accepted cases are a claim that check stays silent.
//
// RED MEANS: the closed builtin table lost an entry or stopped requiring a std declaration, so a
//   number or pointer hash or a HashMap read of the const is refused, or a user extern is trusted.

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
	targets: string[];
	text: string;
}

const CELL = "class Cell { n: number = 7; }\nconst K: Readonly<Cell> = new Cell();\n";
const RUN = "const f = spawn(() => read());\nconsole.log(await f);\n";

const cases: Case[] = [
	{
		name: "a number hash of a field of the const (Float64Bits, HiXorLo)",
		refused: false,
		targets: ["c"],
		text: CELL
			+ "function peek(c: Readonly<Cell>): int64 { return c.n.hash(); }\n"
			+ "function read(): int64 { return peek(K); }\n" + RUN,
	},
	{
		name: "a pointer hash of the const (PtrBits, HiXorLo)",
		refused: false,
		targets: ["c"],
		text: CELL + "function read(): int64 { return K.hash(); }\n" + RUN,
	},
	{
		name: "a HashMap read of the const (MapFatal)",
		refused: false,
		targets: ["c"],
		text: "const M: Readonly<HashMap<int32, int32>> = new HashMap<int32, int32>();\n"
			+ "function read(): int32 { return M.has(3) ? 1 : 0; }\n" + RUN,
	},
	{
		name: "a user extern that claims the PtrBits builtin kind",
		refused: true,
		targets: ["c", "js"],
		text: CELL + "@builtin(\"PtrBits\")\nextern function myBits(p: Readonly<Ptr<void>>): uint64;\n"
			+ "function read(): uint64 { return myBits(K as Readonly<Ptr<void>>); }\n" + RUN,
	},
	{
		name: "a user extern called with the const",
		refused: true,
		targets: ["c", "js"],
		text: CELL + "extern function bumpOf(c: Readonly<Cell>): int32;\n"
			+ "function read(): int32 { return bumpOf(K); }\n" + RUN,
	},
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/readonlyConstStdBuiltinsWriteNothing/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, c.text);
	for (const target of c.targets) {
		const r = execFileResult(msc, ["check", `--target=${target}`, `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		const name = `${c.name} [${target}]`;
		if (c.refused && (r.exitCode == 0 || !out.includes(WRITES) || !out.includes(MODULE_STATE_RULE))) report(`${name}: not refused: ${out}`);
		if (!c.refused && r.exitCode != 0) report(`${name}: check failed: ${out}`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
