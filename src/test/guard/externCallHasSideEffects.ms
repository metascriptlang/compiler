// guard: a call to a C extern counts as a side effect, so its result is not a fresh value: moving it
// into a task is refused (E148), and a module const it builds is not a value a task may read; the
// same shapes through a routine with a body that builds the value stay accepted, on C and JS.
//
// WHY A SUBPROCESS: the accepted case is a claim that check stays silent.
//
// RED MEANS: the side-effect walk lost its external-call branch for `extern function`, whose parsed
//   body is an empty block, so an extern that may keep an alias passes as a fresh constructor.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

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
	expect: string;
	text: string;
}

const CELL = "class Cell { n: int32 = 7; }\n";
const MOVE = "function run(): int32 {\n\tconst x = make();\n\tconst f = spawn((): int32 => x.n, { move: [x] });\n\treturn await f;\n}\nconsole.log(run());\n";
const READ = "const K: Readonly<Cell> = make();\nfunction read(): int32 { return K.n; }\nconst f = spawn(() => read());\nconsole.log(await f);\n";
const EXTERN = "extern function make(): Cell;\n";
const BODY = "function make(): Cell { return new Cell(); }\n";

const cases: Case[] = [
	{ name: "a value an extern returns, moved into a task", expect: "a call with side effects may keep an alias of it: calls the external 'make'", text: CELL + EXTERN + MOVE },
	{ name: "a module const an extern builds, read by a task", expect: "uses module-level 'K'", text: CELL + EXTERN + READ },
	{ name: "a value a routine with a body builds, moved into a task", expect: "", text: CELL + BODY + MOVE },
	{ name: "a module const a routine with a body builds, read by a task", expect: "", text: CELL + BODY + READ },
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/externCallHasSideEffects/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, c.text);
	for (const target of ["c", "js"]) {
		const r = execFileResult(msc, ["check", `--target=${target}`, `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		const name = `${c.name} [${target}]`;
		if (c.expect != "" && (r.exitCode == 0 || !out.includes(c.expect))) report(`${name}: not refused: ${out}`);
		if (c.expect == "" && r.exitCode != 0) report(`${name}: check failed: ${out}`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
