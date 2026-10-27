// A generic instance is emitted by the module that minted it, so a module's C never names a type
// only its importers know. Each test builds a small project with the compiler under test ($MSC, else
// `./msc`) and reads the C of each module: a build is the only consumer that routes instances to modules.
import { execFileResult, cwd, env } from "std/process";
import { writeFile, ensureDir, removeAll, readFile, readDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

const LIB = `function helper(x: int32): int32 { return x + 1; }
export function twice<T>(x: T): T { helper(1); return x; }
export class Wrap<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	get(): T { return this.v; }
}
export function nest<T>(x: T): T { return twice<Wrap<T>>(new Wrap<T>(x)).get(); }
`;
const BOX = "export class Box { n: int32 = 3; }\n";

function project(name: string, main: string): string {
	const dir = `${root}/out/instanceHome/${name}`;
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/lib.ms`, LIB);
	writeFile(`${dir}/box.ms`, BOX);
	writeFile(`${dir}/main.ms`, main);
	return dir;
}

function emittedC(dir: string, module: string): string {
	const r = execFileResult(msc, ["build", `${dir}/main.ms`, "--emit=c", "--output=prog"], dir);
	if (r.exitCode != 0) return `BUILD-FAILED ${r.output}${r.errorOutput}`;
	for (const name of readDir(`${dir}/out/debug`)) {
		if (!name.endsWith(`Z${module}Oms.c`)) continue;
		const text = readFile(`${dir}/out/debug/${name}`);
		if (text.ok) return text.value;
	}
	return `BUILD-FAILED no C for ${module}`;
}

function defines(c: string, stem: string): boolean {
	for (const line of c.split("\n")) {
		if (line.contains(stem) && line.endsWith(") {")) return true;
	}
	return false;
}

test "a generic function instance is emitted by the module that minted it, not the one that declares the generic" {
	const dir = project("fn", "import { twice } from \"./lib\";\nimport { Box } from \"./box\";\nconsole.log(twice(new Box()).n);\n");
	const lib = emittedC(dir, "lib");
	const main = emittedC(dir, "main");
	assert !lib.startsWith("BUILD-FAILED") && !main.startsWith("BUILD-FAILED"), lib + main;
	assert !lib.contains("Box"), "lib does not import Box, so its C names no Box";
	assert defines(main, "twice_") && main.contains("ref_Box"), "main defines the twice instance over Box";
}

test "a generic class instance is emitted by the module that minted it" {
	const dir = project("class", "import { Wrap } from \"./lib\";\nimport { Box } from \"./box\";\nconsole.log(new Wrap<Box>(new Box()).get().n);\n");
	const lib = emittedC(dir, "lib");
	const main = emittedC(dir, "main");
	assert !lib.startsWith("BUILD-FAILED") && !main.startsWith("BUILD-FAILED"), lib + main;
	assert !lib.contains("Box"), "lib does not import Box, so its C names no Box";
	assert defines(main, "Wrap_get_") && defines(main, "_init("), "main defines the Wrap instance methods and constructor";
}

test "an instance minted inside another instance is emitted by the module that minted the outer one" {
	const dir = project("nested", "import { nest } from \"./lib\";\nimport { Box } from \"./box\";\nconsole.log(nest(new Box()).n);\n");
	const lib = emittedC(dir, "lib");
	const main = emittedC(dir, "main");
	assert !lib.startsWith("BUILD-FAILED") && !main.startsWith("BUILD-FAILED"), lib + main;
	assert !lib.contains("Box"), "lib does not import Box, so its C names no Box";
	assert defines(main, "nest_") && defines(main, "twice_"), "main defines nest and the twice it calls";
}

test "two modules minting the same instance link into one program that runs" {
	const dir = project("shared", "import { twice } from \"./lib\";\nimport { other } from \"./other\";\nconsole.log(twice<int32>(5), other());\n");
	writeFile(`${dir}/other.ms`, "import { twice } from \"./lib\";\nexport function other(): int32 { return twice<int32>(7); }\n");
	const built = execFileResult(msc, ["build", `${dir}/main.ms`, "--output=prog"], dir);
	assert built.exitCode == 0, `${built.output}${built.errorOutput}`;
	const ran = execFileResult(`${dir}/prog`, [], dir);
	assert ran.exitCode == 0 && ran.output.trim() == "5 7", ran.output;
}

test "the JS backend still builds an instance minted by an importer" {
	const dir = project("js", "import { twice } from \"./lib\";\nimport { Box } from \"./box\";\nconsole.log(twice(new Box()).n);\n");
	const built = execFileResult(msc, ["build", `${dir}/main.ms`, "--target=js", "--output=out.js"], dir);
	assert built.exitCode == 0, `${built.output}${built.errorOutput}`;
	const js = readFile(`${dir}/out.js`);
	assert js.ok && js.value.contains("twice"), "the instance is in the bundle";
}

test "one instance minted by two modules is one routine with one static state" {
	const dir = project("static", "import { counter } from \"./lib\";\nimport { useIt } from \"./other\";\nconsole.log(useIt(), counter<string>(\"b\"), counter<string>(\"c\"));\n");
	writeFile(`${dir}/lib.ms`, "export function counter<T>(x: T): int32 {\n\tstatic const seen: int32[] = [];\n\tseen.push(1);\n\treturn seen.length;\n}\n");
	writeFile(`${dir}/other.ms`, "import { counter } from \"./lib\";\nexport function useIt(): int32 { return counter<string>(\"a\"); }\n");
	const built = execFileResult(msc, ["build", `${dir}/main.ms`, "--output=prog"], dir);
	assert built.exitCode == 0, `${built.output}${built.errorOutput}`;
	const ran = execFileResult(`${dir}/prog`, [], dir);
	assert ran.exitCode == 0 && ran.output.trim() == "1 2 3", ran.output;
}

test "overloads of one generic keep their own instance over the same type arguments" {
	const dir = project("overload", "import { twice } from \"./lib\";\nimport { a } from \"./other\";\nconsole.log(twice<int32>(7), a());\n");
	writeFile(`${dir}/lib.ms`, "export function twice<T>(x: T): T { return x; }\nexport function twice<T>(x: T, n: int32): T { return x; }\n");
	writeFile(`${dir}/other.ms`, "import { twice } from \"./lib\";\nexport function a(): int32 { return twice<int32>(5, 2) + 1; }\n");
	const built = execFileResult(msc, ["build", `${dir}/main.ms`, "--output=prog"], dir);
	assert built.exitCode == 0, `${built.output}${built.errorOutput}`;
	const ran = execFileResult(`${dir}/prog`, [], dir);
	assert ran.exitCode == 0 && ran.output.trim() == "7 6", ran.output;
}
