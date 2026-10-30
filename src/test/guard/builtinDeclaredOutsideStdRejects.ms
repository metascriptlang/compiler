// guard: @builtin is refused in a module outside the std tree the compiler resolved, on a function,
// an extern and a method, and in a user file whose path spells a std module, so every reader of a
// builtin kind can trust that std declared it. @iteratorHelper is open to every module: a
// well-shaped user generator is accepted and each misuse shape is refused at its declaration.
//
// WHY A SUBPROCESS: the fake std file needs a directory tree beside the entry module.
//
// RED MEANS: a user module can claim a builtin kind (PromiseSpawn, PtrBits, ToString) and borrow
//   the checker's trust in the std declaration, std membership is read from a path spelling, a
//   well-shaped user @iteratorHelper is refused, or a misused one reaches the lowering.

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
	refusal: string;
	declaredIn: string;
	files: { path: string, text: string }[];
}

const FAKE_STRUCT = "@builtin(\"PtrBits\")\nexport extern function fakeBits(p: Ptr<void>): uint64;\n";

const cases: Case[] = [
	{
		name: "a user function claiming PromiseSpawn",
		refusal: "@builtin(\"PromiseSpawn\") is reserved for the standard library",
		declaredIn: "/main.ms'",
		files: [{ path: "main.ms", text: "@builtin(\"PromiseSpawn\")\nfunction mySpawn(f: () => int32): int32 { return f(); }\nconsole.log(mySpawn(() => 1));\n" }],
	},
	{
		name: "a user extern claiming PtrBits",
		refusal: "@builtin(\"PtrBits\") is reserved for the standard library",
		declaredIn: "/main.ms'",
		files: [{ path: "main.ms", text: "@builtin(\"PtrBits\")\nextern function myBits(p: Ptr<void>): uint64;\nconsole.log(1);\n" }],
	},
	{
		name: "a user method claiming ToString",
		refusal: "@builtin(\"ToString\") is reserved for the standard library",
		declaredIn: "/main.ms'",
		files: [{ path: "main.ms", text: "class C {\n\t@builtin(\"ToString\")\n\tshow(): string { return \"c\"; }\n}\nconsole.log(new C().show());\n" }],
	},
	{
		name: "a user file at std/core/struct.ms claiming PtrBits",
		refusal: "@builtin(\"PtrBits\") is reserved for the standard library",
		declaredIn: "/std/core/struct.ms'",
		files: [
			{ path: "std/core/struct.ms", text: FAKE_STRUCT },
			{ path: "main.ms", text: "import { fakeBits } from \"./std/core/struct\";\nconsole.log(1);\n" },
		],
	},
];

const HELPER = "@iteratorHelper\n";
const NEEDS_SOURCE = "@iteratorHelper needs the source iterator (an Iterator<T>) as the first parameter";
const SHAPE_REFUSALS: { name: string, text: string, refusal: string }[] = [
	{ name: "no parameters", text: `${HELPER}function* h(): Iterator<int32> { yield 1; }`, refusal: NEEDS_SOURCE },
	{ name: "a first parameter that is not an iterator", text: `${HELPER}function* h(n: int32): Iterator<int32> { yield n; }`, refusal: NEEDS_SOURCE },
	{ name: "a function that is not a generator", text: `${HELPER}function h(it: Iterator<int32>): Iterator<int32> { return it; }`, refusal: "@iteratorHelper applies to a generator function with a body" },
	{ name: "a return type that is not an iterator", text: `${HELPER}function* h(it: Iterator<int32>): int32 { yield 1; }`, refusal: "@iteratorHelper must return an Iterator<T>" },
	{ name: "an async generator", text: `${HELPER}async function* h(it: Iterator<int32>): Iterator<int32> { yield 1; }`, refusal: "@iteratorHelper does not apply to an async generator" },
];
const USER_HELPERS = `${HELPER}function* dedupe<T>(it: Iterator<T>): Iterator<T> { for (const x of it) yield x; }\n${HELPER}function* twice(this it: Iterator<int32>): Iterator<int32> { for (const x of it) { yield x; yield x; } }\nconsole.log(1);\n`;

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
		if (r.exitCode == 0 || !out.includes(c.refusal) || !out.includes(c.declaredIn)) report(`${c.name} [${target}]: not refused at its declaration: ${out}`);
	}
}

function checkUserFile(label: string, text: string, refusal: string): void {
	slot += 1;
	const dir = `${root}/out/guard/builtinDeclaredOutsideStdRejects/${slot}`;
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, text);
	for (const target of ["c", "js"]) {
		const r = execFileResult(msc, ["check", `--target=${target}`, `${dir}/main.ms`]);
		const out = `${r.output}${r.errorOutput}`;
		if (refusal == "") {
			if (r.exitCode != 0) report(`${label} [${target}]: refused: ${out}`);
		} else if (r.exitCode == 0 || !out.includes(refusal) || !out.includes("/main.ms:1:1")) {
			report(`${label} [${target}]: not refused at its declaration: ${out}`);
		}
	}
}

checkUserFile("a well-shaped user @iteratorHelper", USER_HELPERS, "");
for (const c of SHAPE_REFUSALS) checkUserFile(`@iteratorHelper on ${c.name}`, `${c.text}\nconsole.log(1);\n`, c.refusal);

if (failed != 0) exit(1);
console.log("GUARD-OK");
