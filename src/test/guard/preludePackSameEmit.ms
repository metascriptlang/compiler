// A build emits the same C and JS whether the prelude pack missed, hit, or is disabled. A macro
// builds the Raiser prelude on its first expansion, inside the calling module's gensym unit, so a
// miss that checked that prelude from source must leave the module's hygiene ($h) and template
// ($t) numbering where a hit leaves it.
//
// WHY A SUBPROCESS: a pack miss and a pack hit are two compiler processes sharing one
// $HOME/.metascript/cache/prelude. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: all four cells differed between the miss and the hit (`v$h6` against `v$h2`,
// `tdollart6` against `tdollart2`). GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardPreludePackSameEmit`;
const realHome = env.get("HOME");

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function textOf(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : "";
}

function emitted(runDir: string, backend: string): string {
	if (backend == "js") return textOf(`${runDir}/out.js`);
	const where = `${runDir}/out/debug`;
	if (!exists(where)) return "";
	const names = readDir(where).filter((n: string): boolean => n.endsWith(".c"));
	names.sort();
	let all = "";
	for (const n of names) all = `${all}== ${n}\n${textOf(`${where}/${n}`)}`;
	return all;
}

function build(label: string, run: string, home: string, program: string, backend: string, packOff: boolean): string {
	const runDir = `${dir}/${label}/${run}`;
	ensureDir(runDir);
	const args: string[] = backend == "js"
		? ["build", `${dir}/${program}`, "--target=js", "--output=out.js"]
		: ["build", `${dir}/${program}`, "--emit=c", "--cc=clang", "--output=out"];
	env.set("HOME", home);
	if (packOff) env.set("MSC_NO_PRELUDE_PACK", "1");
	const r = execFileResult(msc, args, runDir);
	env.delete("MSC_NO_PRELUDE_PACK");
	if (realHome != "") env.set("HOME", realHome);
	else env.delete("HOME");
	if (r.exitCode != 0) {
		report(`${label} ${run}: build failed: ${r.output}${r.errorOutput}`);
		return "";
	}
	const text = emitted(runDir, backend);
	if (text == "") report(`${label} ${run}: no emitted ${backend} found under ${runDir}`);
	return text;
}

function firstDifference(a: string, b: string): string {
	const al = a.split("\n");
	const bl = b.split("\n");
	for (let i = 0; i < al.length && i < bl.length; i += 1) {
		if (al[i] != bl[i]) return `line ${i + 1}: ${al[i]}  <>  ${bl[i]}`;
	}
	return `lengths ${al.length} and ${bl.length} lines`;
}

function cell(program: string, backend: string): void {
	const label = `${program.replace(".ms", "")}-${backend}`;
	const home = `${dir}/${label}/home`;
	ensureDir(`${home}/.metascript/cache`);
	const miss = build(label, "miss", home, program, backend, false);
	const hit = build(label, "hit", home, program, backend, false);
	const off = build(label, "off", home, program, backend, true);
	if (miss == "" || hit == "" || off == "") return;
	if (miss != hit) report(`${label}: a pack miss and a pack hit emit different code, ${firstDifference(miss, hit)}`);
	if (off != hit) report(`${label}: the pack disabled and a pack hit emit different code, ${firstDifference(off, hit)}`);
}

env.delete("MSC_NO_PRELUDE_PACK");
env.delete("MSC_NO_GLOBAL_CACHE");
removeAll(dir);
ensureDir(dir);

const seedCallNode = "{ kind: NodeKind.CallExpr, line: 0, column: 0, callee: { kind: NodeKind.Identifier, line: 0, column: 0, name: \"seed\" }, arguments: [] }";
writeFile(`${dir}/seeding.ms`, [
	"import { Node, NodeKind, DeclKind } from \"std/meta\";",
	"export macro seeded(): Node {",
	"\treturn {",
	"\t\tkind: NodeKind.SpliceMany, line: 0, column: 0,",
	"\t\tspliceNodes: [",
	`\t\t\t{ kind: NodeKind.VariableDecl, line: 0, column: 0, declName: "v", declType: "int32", initializer: ${seedCallNode}, declKind: DeclKind.Const, nameLocation: { line: 0, column: 0 } },`,
	"\t\t\t{ kind: NodeKind.Identifier, line: 0, column: 0, name: \"v\" },",
	"\t\t],",
	"\t};",
	"}",
	`export macro seedCall(): Node { return ${seedCallNode}; }`,
	"",
].join("\n"));
writeFile(`${dir}/hygiene.ms`, "import { seeded } from \"./seeding\";\nfunction seed(): int32 { return 21; }\nfunction viaMacro(): int32 { return seeded(); }\nconsole.log(viaMacro());\n");
writeFile(`${dir}/templated.ms`, "import { seedCall } from \"./seeding\";\nfunction seed(): int32 { return 21; }\ntemplate logDoubled(x: int32): void {\n\tconst t = x + x;\n\tconsole.log(t);\n}\nfunction viaTemplate(): void { logDoubled(seedCall()); }\nviaTemplate();\n");

for (const program of ["hygiene.ms", "templated.ms"]) {
	for (const backend of ["js", "c"]) cell(program, backend);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
