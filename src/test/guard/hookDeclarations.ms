// guard: a lifecycle hook is bound to its type at the declaration, or refused there.
//
// INVARIANT: a hook the compiler accepts is a hook that runs. The reference binds a hook to its
//   type in `bindHookToType` and refuses one that cannot bind: a type bound operation can be defined
//   only in the module of its type (semstmts 2205-2207), and a wrong signature is "signature for
//   '=…' must be …" (semstmts 2220-2260, `bindDupHook` 2192-2203).
//
// WHY A SUBPROCESS: the observable is the CLI verdict on C and on JS; the compiler under test is
//   $MSC when the runner exports one, else `./msc` beside the recompiler root.
//
// RED MEANS: a declaration the reference refuses compiled, so its hook is accepted and never runs
//   (or fails later in the C compiler), or a declaration the reference binds was refused.

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

interface Source {
	path: string;
	text: string;
}

interface Case {
	name: string;
	files: Source[];
	refused: string;
}

const cases: Case[] = [];

function refuse(name: string, refused: string, files: Source[]): void {
	cases.push({ name, files, refused });
}

function accept(name: string, files: Source[]): void {
	cases.push({ name, files, refused: "" });
}

function one(text: string): Source[] {
	return [{ path: "main.ms", text }];
}

const libStruct = "export struct S { id: int32; name: string; }\n";

refuse("a hook declared outside the module of its type", "type bound operation 'onDestroy' can be defined only in the same module with its type (S)", [
	{ path: "lib.ms", text: libStruct },
	{ path: "main.ms", text: "import { S } from \"./lib\";\nfunction onDestroy(this x: S): void { console.log(\"destroy\"); }\nconst a: S = { id: 1, name: \"n\" };\nconsole.log(a.id.toString());\n" },
]);

accept("a hook declared beside its type, used from another module", [
	{ path: "lib.ms", text: libStruct + "export function onDestroy(this x: S): void { console.log(\"destroy\"); }\n" },
	{ path: "main.ms", text: "import { S } from \"./lib\";\nconst a: S = { id: 1, name: \"n\" };\nconsole.log(a.id.toString());\n" },
]);

function verdict(dir: string, target: string): string {
	const args = target == "c" ? ["check", `${dir}/main.ms`] : ["check", `${dir}/main.ms`, "--target=js"];
	const r = execFileResult(msc, args);
	return `${r.exitCode == 0 ? "OK" : "ERR"}\n${r.output}${r.errorOutput}`;
}

let slot = 0;
for (const c of cases) {
	slot += 1;
	const dir = `${root}/out/guard/hookDeclarations/${slot}`;
	ensureDir(dir);
	for (const f of c.files) writeFile(`${dir}/${f.path}`, f.text);
	for (const target of ["c", "js"]) {
		const out = verdict(dir, target);
		const accepted = out.startsWith("OK\n");
		if (c.refused == "") {
			if (!accepted) report(`[${target}] ${c.name}: refused: ${out}`);
		} else if (accepted) {
			report(`[${target}] ${c.name}: accepted, the hook would never run`);
		} else if (!out.includes(c.refused)) {
			report(`[${target}] ${c.name}: refused without the rule named (${c.refused}): ${out}`);
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
