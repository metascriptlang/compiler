// guard: @builtin is refused in a module outside the std tree the compiler resolved, on a
// function, an extern and a method, and in a user file whose path spells std/core/struct.ms, so
// every reader of a builtin kind can trust that std declared it.
//
// WHY A SUBPROCESS: the fake std file needs a directory tree beside the entry module.
//
// RED MEANS: a user module can claim a builtin kind (PromiseSpawn, PtrBits, ToString) and borrow
//   the checker's trust in the std declaration, or std membership is read from a path spelling.

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
	kind: string;
	declaredIn: string;
	files: { path: string, text: string }[];
}

const FAKE_STRUCT = "@builtin(\"PtrBits\")\nexport extern function fakeBits(p: Ptr<void>): uint64;\n";

const cases: Case[] = [
	{
		name: "a user function claiming PromiseSpawn",
		kind: "PromiseSpawn",
		declaredIn: "/main.ms'",
		files: [{ path: "main.ms", text: "@builtin(\"PromiseSpawn\")\nfunction mySpawn(f: () => int32): int32 { return f(); }\nconsole.log(mySpawn(() => 1));\n" }],
	},
	{
		name: "a user extern claiming PtrBits",
		kind: "PtrBits",
		declaredIn: "/main.ms'",
		files: [{ path: "main.ms", text: "@builtin(\"PtrBits\")\nextern function myBits(p: Ptr<void>): uint64;\nconsole.log(1);\n" }],
	},
	{
		name: "a user method claiming ToString",
		kind: "ToString",
		declaredIn: "/main.ms'",
		files: [{ path: "main.ms", text: "class C {\n\t@builtin(\"ToString\")\n\tshow(): string { return \"c\"; }\n}\nconsole.log(new C().show());\n" }],
	},
	{
		name: "a user file at std/core/struct.ms claiming PtrBits",
		kind: "PtrBits",
		declaredIn: "/std/core/struct.ms'",
		files: [
			{ path: "std/core/struct.ms", text: FAKE_STRUCT },
			{ path: "main.ms", text: "import { fakeBits } from \"./std/core/struct\";\nconsole.log(1);\n" },
		],
	},
];

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/builtinDeclaredOutsideStdRejects/${slot}`;
	for (const f of c.files) {
		const path = `${dir}/${f.path}`;
		ensureDir(path.slice(0, path.lastIndexOf("/")));
		writeFile(path, f.text);
	}
	for (const target of ["c", "js"]) {
		const r = execFileResult(msc, ["check", `--target=${target}`, `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		const refusal = `@builtin("${c.kind}") is reserved for the standard library`;
		if (r.exitCode == 0 || !out.includes(refusal) || !out.includes(c.declaredIn)) report(`${c.name} [${target}]: not refused at its declaration: ${out}`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
