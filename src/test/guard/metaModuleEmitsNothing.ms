// std/meta is the compile-time API: a program that only uses macros emits nothing from it, on the
// host and on `--os=solana`, and what only a macro body uses stays out of its module's C. A
// program that calls a std/meta function at run time still emits the module.
// NIM-REF CG-15 (emission on demand), CG-19 (compile-time-only declarations emit no code).
//
// WHY A SUBPROCESS: the observable is which modules reach the emitted C of a multi-module
// program. The compiler under test is $MSC, else `./msc`; the C is read from `--emit=c`.
//
// RED PRE-FIX: every cell emitted std/meta/node (its exported classes' `_init` and the
// `nodeCache` init were roots). GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardMetaModuleEmitsNothing`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function emittedFiles(cell: string): string[] {
	const found: string[] = [];
	for (const mode of ["debug", "release"]) {
		const where = `${cell}/out/${mode}`;
		if (!exists(where)) continue;
		for (const entry of readDir(where)) {
			if (entry.endsWith(".c")) found.push(`${where}/${entry}`);
		}
	}
	return found;
}

function emit(label: string, extra: string[], names: string[], sources: string[]): string[] {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	for (let i = 0; i < names.length; i += 1) writeFile(`${cell}/${names[i]}`, sources[i]);
	const args: string[] = ["build", "main.ms", "--emit=c", "--output=main.c"];
	for (const a of extra) args.push(a);
	const built = execFileResult(msc, args, cell);
	if (built.exitCode != 0) {
		report(`${label}: --emit=c failed: ${built.output}${built.errorOutput}`);
		return [];
	}
	return emittedFiles(cell);
}

function metaFiles(files: string[]): string[] {
	const found: string[] = [];
	for (const f of files) {
		if (f.includes("ZmetaZ")) found.push(f);
	}
	return found;
}

function textOf(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : "";
}

function moduleFile(files: string[], moduleName: string): string {
	for (const f of files) {
		if (f.includes(`Z${moduleName}Oms.c`)) return f;
	}
	return "";
}

removeAll(dir);
ensureDir(dir);

const macroModule = [
	"import { Node, NodeKind } from \"std/meta\";",
	"function passThrough(x: Node): Node { return x; }",
	"export macro twice(x: Node): Node {",
	"\treturn { kind: NodeKind.BinaryExpr, line: x.line, column: x.column, operator: \"+\", left: passThrough(x), right: x };",
	"}",
	"export function runtimeValue(): int32 { return 21; }",
	"",
].join("\n");
const macroMain = "import { twice, runtimeValue } from \"./doubling\";\nfunction main(): void {\n\tconst v: int32 = twice(runtimeValue());\n\tconsole.log(v);\n}\nmain();\n";

function macroCell(label: string, extra: string[]): void {
	const files = emit(label, extra, ["doubling.ms", "main.ms"], [macroModule, macroMain]);
	if (files.length == 0) return;
	const meta = metaFiles(files);
	if (meta.length > 0) report(`${label}: a program that only uses a macro emitted std/meta: ${meta.length} module(s), first ${meta[0]}`);
	const owner = moduleFile(files, "doubling");
	if (owner == "") {
		report(`${label}: the module that defines the macro and a run-time function was not emitted`);
		return;
	}
	if (textOf(owner).includes("passThrough")) report(`${label}: a helper only the macro body uses was emitted`);
	if (!textOf(owner).includes("runtimeValue")) report(`${label}: the run-time function of the macro module was not emitted`);
}

macroCell("host", []);
macroCell("solana", ["--os=solana"]);

const used = emit("runtimeUse", [], ["main.ms"], [
	"import { makeLoc } from \"std/meta\";\nconsole.log(makeLoc(3, 4).line);\n",
]);
if (used.length > 0 && metaFiles(used).length == 0) report("a program that calls std/meta makeLoc at run time did not emit std/meta");

if (failed != 0) exit(1);
console.log("GUARD-OK");
