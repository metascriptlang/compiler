// What a module's lowering reads from another module (an inlinable iterator body) comes from its own
// import closure, so its C never depends on which module the build lowers first. Each test builds a small project
// with the compiler under test ($MSC, else `./msc`) and reads the C of each module.
import { execFileResult, cwd, env } from "std/process";
import { writeFile, ensureDir, removeAll, readFile, readDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

const CYCLE_B = `import { tag } from "./a";
export function* nums(n: int32): Iterator<int32> {
	for (let i: int32 = 0; i < n; i += 1) yield i * 2;
}
export function evens(n: int32): Iterator<int32> { return nums(n); }
export function label(): string { return tag; }
`;

const CYCLE_A = `import { nums, evens } from "./b";
export const tag = "a";
export function total(n: int32): int32 {
	let s: int32 = 0;
	for (const x of nums(n)) s += x;
	return s;
}
export function viaForwarder(n: int32): int32 {
	let s: int32 = 0;
	for (const x of evens(n)) s += x;
	return s;
}
`;

function project(name: string, files: HashMap<string, string>): string {
	const dir = `${root}/out/lowerOrder/${name}`;
	removeAll(dir);
	ensureDir(dir);
	for (const file of files.keys()) writeFile(`${dir}/${file}`, files.get(file)!);
	return dir;
}

function cycleProject(name: string): string {
	const files = new HashMap<string, string>();
	files.set("a.ms", CYCLE_A);
	files.set("b.ms", CYCLE_B);
	files.set("mainAB.ms", "import { total, viaForwarder } from \"./a\";\nimport { label } from \"./b\";\nconsole.log(total(4), viaForwarder(3), label());\n");
	files.set("mainBA.ms", "import { label } from \"./b\";\nimport { total, viaForwarder } from \"./a\";\nconsole.log(total(4), viaForwarder(3), label());\n");
	return project(name, files);
}

function moduleC(dir: string, entry: string, module: string): string {
	removeAll(`${dir}/out`);
	const r = execFileResult(msc, ["build", `${dir}/${entry}.ms`, "--emit=c", "--output=prog"], dir);
	if (r.exitCode != 0) return `BUILD-FAILED ${entry}: ${r.output}${r.errorOutput}`;
	for (const name of readDir(`${dir}/out/debug`)) {
		if (name == `${module}Oms.c` || name.endsWith(`Z${module}Oms.c`)) {
			const text = readFile(`${dir}/out/debug/${name}`);
			return text.ok ? text.value : `BUILD-FAILED unreadable ${name}`;
		}
	}
	return `BUILD-FAILED no C for ${module}`;
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

function names(c: string, routine: string): boolean {
	return c.contains(`${routine}__`);
}

test "a loop over a generator of the other module of an import cycle is inlined in either import order" {
	const dir = cycleProject("cycle");
	const ab = moduleC(dir, "mainAB", "a");
	const ba = moduleC(dir, "mainBA", "a");
	const order = sameC("a's C changes with the import order of the cycle", ab, ba);
	assert order == "", order;
	assert !names(ab, "nums"), `a still calls b's generator:\n${ab}`;
	assert runs(dir, "mainAB") == "12 6 a", "mainAB prints total(4), viaForwarder(3), label()";
	assert runs(dir, "mainBA") == "12 6 a", "mainBA prints total(4), viaForwarder(3), label()";
}

test "a loop over a forwarder of the other module of an import cycle is inlined in either import order" {
	const dir = cycleProject("cycleForwarder");
	const ab = moduleC(dir, "mainAB", "a");
	const ba = moduleC(dir, "mainBA", "a");
	assert !names(ab, "evens") && !names(ba, "evens"), `a still calls b's forwarder:\n${ab}\n---\n${ba}`;
}
