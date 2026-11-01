// A lifted hook (anonymous struct, tuple, generic instance) and its TypeInfo belong to the modules whose
// lowering needs them, so a module's C never depends on which sibling the build lowered first. Each test
// builds a small project with the compiler under test ($MSC, else `./msc`) and reads the C of each module.
import { execFileResult, cwd, env } from "std/process";
import { writeFile, ensureDir, removeAll, readFile, readDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

function sibling(name: string, tag: string, n: int32): string {
	return `export function ${name}(): int32 {
	const xs: { s: string, n: int32 }[] = [{ s: "${tag}" + String(${n}), n: ${n} }];
	const t: [string, int32] = ["${tag}" + String(${n}), ${n}];
	return (xs.length + t[1]) as int32;
}
`;
}

function genericSibling(name: string, tag: string, n: int32): string {
	return `import { Pair } from "./rec";
export function ${name}(): int32 {
	const p: Pair<string> = { x: "${tag}" + String(${n}), y: "z" };
	return p.x.length as int32;
}
`;
}

function project(name: string): string {
	const dir = `${root}/out/hookHome/${name}`;
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/a.ms`, sibling("fa", "a", 1));
	writeFile(`${dir}/b.ms`, sibling("fb", "b", 2));
	writeFile(`${dir}/rec.ms`, "export interface Pair<T> { x: T; y: T; }\n");
	writeFile(`${dir}/ga.ms`, genericSibling("ga", "a", 1));
	writeFile(`${dir}/gb.ms`, genericSibling("gb", "b", 22));
	writeFile(`${dir}/mainA.ms`, "import { fa } from \"./a\";\nconsole.log(fa());\n");
	writeFile(`${dir}/mainAB.ms`, "import { fa } from \"./a\";\nimport { fb } from \"./b\";\nconsole.log(fa() + fb());\n");
	writeFile(`${dir}/mainBA.ms`, "import { fb } from \"./b\";\nimport { fa } from \"./a\";\nconsole.log(fa() + fb());\n");
	writeFile(`${dir}/gmainA.ms`, "import { ga } from \"./ga\";\nconsole.log(ga());\n");
	writeFile(`${dir}/gmainAB.ms`, "import { ga } from \"./ga\";\nimport { gb } from \"./gb\";\nconsole.log(ga() + gb());\n");
	writeFile(`${dir}/gmainBA.ms`, "import { gb } from \"./gb\";\nimport { ga } from \"./ga\";\nconsole.log(ga() + gb());\n");
	return dir;
}

function emitted(dir: string, entry: string): HashMap<string, string> {
	const files = new HashMap<string, string>();
	removeAll(`${dir}/out`);
	const r = execFileResult(msc, ["build", `${dir}/${entry}.ms`, "--emit=c", "--output=prog"], dir);
	if (r.exitCode != 0) {
		files.set("BUILD-FAILED", `${entry}: ${r.output}${r.errorOutput}`);
		return files;
	}
	for (const name of readDir(`${dir}/out/debug`)) {
		if (!name.endsWith(".c")) continue;
		const text = readFile(`${dir}/out/debug/${name}`);
		if (text.ok) files.set(name, text.value);
	}
	return files;
}

function moduleC(files: HashMap<string, string>, module: string): string {
	if (files.has("BUILD-FAILED")) return `BUILD-FAILED ${files.get("BUILD-FAILED")!}`;
	for (const name of files.keys()) {
		if (name == `${module}Oms.c` || name.endsWith(`Z${module}Oms.c`)) return files.get(name)!;
	}
	return `BUILD-FAILED no C for ${module}`;
}

function definedName(line: string): string {
	if (!line.endsWith(") {")) return "";
	const open = line.indexOf("(");
	if (open < 0) return "";
	const head = line.substring(0, open);
	const space = head.lastIndexOf(" ");
	return space < 0 ? head : head.substring(space + 1);
}

function duplicateDefinitions(files: HashMap<string, string>, stem: string): string {
	if (files.has("BUILD-FAILED")) return files.get("BUILD-FAILED")!;
	const seen = new HashMap<string, string>();
	let found = 0;
	let report = "";
	for (const file of files.keys()) {
		for (const line of files.get(file)!.split("\n")) {
			const name = definedName(line);
			if (name == "" || !name.contains(stem) || !name.endsWith("Destroy")) continue;
			found += 1;
			const first = seen.get(name);
			if (first != null) report += `${name} is defined in ${first} and ${file}\n`;
			else seen.set(name, file);
		}
	}
	return found == 0 ? `no definition of a ${stem}…Destroy hook` : report;
}

function typeInfoOwner(files: HashMap<string, string>, stem: string): string {
	if (files.has("BUILD-FAILED")) return files.get("BUILD-FAILED")!;
	for (const file of files.keys()) {
		for (const line of files.get(file)!.split("\n")) {
			if (line.startsWith(`msTypeInfo ${stem}`) && line.contains("TypeInfo = {")) return file;
		}
	}
	return `no TypeInfo definition for ${stem}`;
}

function runs(dir: string, entry: string): string {
	removeAll(`${dir}/out`);
	const built = execFileResult(msc, ["build", `${dir}/${entry}.ms`, "--output=prog"], dir);
	if (built.exitCode != 0) return `BUILD-FAILED ${built.output}${built.errorOutput}`;
	const ran = execFileResult(`${dir}/prog`, [], dir);
	return ran.exitCode == 0 ? ran.output.trim() : `exit ${ran.exitCode} ${ran.output}${ran.errorOutput}`;
}

function sameC(label: string, left: string, right: string): string {
	if (left.startsWith("BUILD-FAILED") || right.startsWith("BUILD-FAILED")) return left + right;
	return left == right ? "" : `${label}:\n--- first\n${left}\n--- second\n${right}`;
}

test "a sibling's lifted structural hooks do not depend on whether or in which order the other sibling is built" {
	const dir = project("structural");
	const alone = emitted(dir, "mainA");
	const ab = emitted(dir, "mainAB");
	const ba = emitted(dir, "mainBA");
	const first = sameC("a's C changes when b is built after it", moduleC(alone, "a"), moduleC(ab, "a"));
	assert first == "", first;
	const second = sameC("a's C changes when b is built before it", moduleC(alone, "a"), moduleC(ba, "a"));
	assert second == "", second;
	const order = sameC("b's C changes with the import order of its siblings", moduleC(ab, "b"), moduleC(ba, "b"));
	assert order == "", order;
}

test "two siblings lifting the same structural hooks link one definition of each and run" {
	const dir = project("structuralLink");
	for (const entry of ["mainAB", "mainBA"]) {
		const files = emitted(dir, entry);
		const anon = duplicateDefinitions(files, "msAnon_");
		assert anon == "", anon;
		const tuple = duplicateDefinitions(files, "msTuple_");
		assert tuple == "", tuple;
	}
	assert runs(dir, "mainAB") == "5", "mainAB prints fa() + fb()";
	assert runs(dir, "mainBA") == "5", "mainBA prints fa() + fb()";
}

test "a sibling's generic instance hooks do not depend on whether or in which order the other sibling is built" {
	const dir = project("generic");
	const alone = emitted(dir, "gmainA");
	const ab = emitted(dir, "gmainAB");
	const ba = emitted(dir, "gmainBA");
	const first = sameC("ga's C changes when gb is built after it", moduleC(alone, "ga"), moduleC(ab, "ga"));
	assert first == "", first;
	const second = sameC("ga's C changes when gb is built before it", moduleC(alone, "ga"), moduleC(ba, "ga"));
	assert second == "", second;
	const order = sameC("gb's C changes with the import order of its siblings", moduleC(ab, "gb"), moduleC(ba, "gb"));
	assert order == "", order;
	for (const files of [ab, ba]) {
		const pair = duplicateDefinitions(files, "Pair");
		assert pair == "", pair;
	}
	assert runs(dir, "gmainBA") == "5", "gmainBA prints ga() + gb()";
}

test "the TypeInfo of a lifted anonymous struct has the same owner whichever sibling is imported first" {
	const dir = project("typeInfo");
	const ab = typeInfoOwner(emitted(dir, "mainAB"), "msAnon_");
	const ba = typeInfoOwner(emitted(dir, "mainBA"), "msAnon_");
	assert ab.endsWith(".c") && ab == ba, `owner after a then b: ${ab}; after b then a: ${ba}`;
}
