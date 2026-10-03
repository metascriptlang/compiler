// A class constructor is emitted when the class is used, not because its C name is spelled
// like an exported symbol. A module whose only export a program imports is a class nobody
// constructs is not emitted; `new` of the class, a subclass of it in another module, and an
// `@exportName` function nobody calls all still emit their definition.
// NIM-REF CG-6 (only `exportc` roots a proc at its declaration, ccgexprs.nim nkProcDef branch),
// CG-15 (emission on demand).
//
// WHY A SUBPROCESS: the observable is which modules reach the emitted C of a multi-module
// program. The compiler under test is $MSC, else `./msc`; the C is read from `--emit=c`.
//
// RED PRE-FIX: the unused class cell emitted its module (`<Class>_init` rooted through
// `Symbol.exportName`). GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardClassInitRoot`;

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

function emit(label: string, names: string[], sources: string[]): string[] {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	for (let i = 0; i < names.length; i += 1) writeFile(`${cell}/${names[i]}`, sources[i]);
	const built = execFileResult(msc, ["build", "main.ms", "--emit=c", "--output=main.c"], cell);
	if (built.exitCode != 0) {
		report(`${label}: --emit=c failed: ${built.output}${built.errorOutput}`);
		return [];
	}
	return emittedFiles(cell);
}

function emittedModule(files: string[], moduleName: string): string {
	for (const f of files) {
		if (f.includes(`Z${moduleName}Oms.c`)) return f;
	}
	return "";
}

function textOf(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : "";
}

removeAll(dir);
ensureDir(dir);

const boxModule = "export class Box { n: int32 = 0; }\nexport function classValue(): int32 { return 2; }\n";

const unused = emit("unused", ["boxes.ms", "main.ms"], [
	boxModule,
	"import { Box } from \"./boxes\";\nconsole.log(\"hi\");\n",
]);
if (unused.length > 0 && emittedModule(unused, "boxes") != "") report("an imported class nobody constructs emitted its module");

const built = emit("constructed", ["boxes.ms", "main.ms"], [
	boxModule,
	"import { Box } from \"./boxes\";\nconst b = new Box();\nconsole.log(b.n);\n",
]);
const builtModule = emittedModule(built, "boxes");
if (built.length > 0 && builtModule == "") report("`new Box()` did not emit the module of Box");
if (builtModule != "" && !textOf(builtModule).includes("Box__")) report("`new Box()` emitted no definition for Box");
if (builtModule != "" && !textOf(builtModule).includes("_init(")) report("`new Box()` emitted no class init");

const inherited = emit("inherited", ["base.ms", "derived.ms", "main.ms"], [
	"export class Base { x: int32 = 1; }\n",
	"import { Base } from \"./base\";\nexport class Derived extends Base { y: int32 = 2; }\n",
	"import { Derived } from \"./derived\";\nconst d = new Derived();\nconsole.log(d.x + d.y);\n",
]);
const baseModule = emittedModule(inherited, "base");
if (inherited.length > 0 && baseModule == "") report("a subclass in another module did not emit its base class module");
if (baseModule != "" && !textOf(baseModule).includes("_init(")) report("a subclass in another module emitted no base class init");

const exported = emit("exportName", ["lib.ms", "main.ms"], [
	"@exportName(\"guardKeptSymbol\")\nexport function kept(): int32 { return 1; }\n",
	"import { kept } from \"./lib\";\nconsole.log(\"hi\");\n",
]);
const libModule = emittedModule(exported, "lib");
if (exported.length > 0 && libModule == "") report("an unused `@exportName` function lost its module");
if (libModule != "" && !textOf(libModule).includes("guardKeptSymbol")) report("an unused `@exportName` function lost its C symbol");

if (failed != 0) exit(1);
console.log("GUARD-OK");
