// What a module's lowering reads from another module (an inlinable iterator body, a routine's write
// summary) comes from its own import closure, so its C never depends on which module the build lowers
// first, and a kept session re-lowers it when such a body changes. Each test builds a small project
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

const BASE = "export class Base {\n\tname(): string { return \"b\"; }\n}\n";
const BOX = "export class Inner { s: string = \"x\"; }\nexport class Box { inner: Inner = new Inner(); }\n";
const SIBLING = `import { Base } from "./base";
export class Sub extends Base {
	name(): string { return "s"; }
}
export function mk(): Base { return new Sub(); }
`;

const OVERRIDE_HEAD = "import { Base } from \"./base\";\nimport { Box } from \"./box\";\nlet g = \"x\";\n";
const OVERRIDE_APPEND = OVERRIDE_HEAD + "export function run(o: Base, b: Box): string {\n\tg = g + o.name();\n\treturn g;\n}\n";
const OVERRIDE_CAPTURE = OVERRIDE_HEAD + "export function run(o: Base, b: Box): string {\n\tconst v = b.inner;\n\tconst f = (): string => v.s + \"!\";\n\tconst n = o.name();\n\treturn f() + n;\n}\n";

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

function overrideProject(name: string, m: string): string {
	const files = new HashMap<string, string>();
	files.set("base.ms", BASE);
	files.set("box.ms", BOX);
	files.set("s.ms", SIBLING);
	files.set("m.ms", m);
	files.set("mainSM.ms", "import { mk } from \"./s\";\nimport { run } from \"./m\";\nimport { Box } from \"./box\";\nconsole.log(run(mk(), new Box()));\n");
	files.set("mainMS.ms", "import { run } from \"./m\";\nimport { mk } from \"./s\";\nimport { Box } from \"./box\";\nconsole.log(run(mk(), new Box()));\n");
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

function overrideOrderMismatch(name: string, m: string): string {
	const dir = overrideProject(name, m);
	return sameC("m's C changes with whether the sibling override was lowered first", moduleC(dir, "mainSM", "m"), moduleC(dir, "mainMS", "m"));
}

test "a call dispatched to an override in a module outside the caller's imports lowers the same in either order" {
	const order = overrideOrderMismatch("overrideAppend", OVERRIDE_APPEND);
	assert order == "", order;
	assert runs(`${root}/out/lowerOrder/overrideAppend`, "mainSM") == "xs", "mainSM prints run(mk(), new Box())";
}

test "a closure capture beside a call dispatched to an override outside the caller's imports lowers the same in either order" {
	const order = overrideOrderMismatch("overrideCapture", OVERRIDE_CAPTURE);
	assert order == "", order;
	assert runs(`${root}/out/lowerOrder/overrideCapture`, "mainMS") == "x!s", "mainMS prints run(mk(), new Box())";
}

const KEPT_H = "export class Inner { s: string = \"x\"; }\nexport class H {\n\ts: string = \"x\";\n\tinner: Inner = new Inner();\n}\n";
const KEPT_P = (body: string): string => `import { H, Inner } from "./h";\nfunction helper(h: H): void { ${body} }\nexport function p(h: H): string { helper(h); return "p"; }\n`;
const KEPT_APP = "import { H } from \"../lib/h\";\nimport { run } from \"./m\";\nconsole.log(run(new H()));\n";
const KEPT_HEAD = "import { H } from \"../lib/h\";\nimport { p } from \"../lib/p\";\n";
const KEPT_APPEND = KEPT_HEAD + "export function run(h: H): string {\n\th.s = h.s + p(h);\n\treturn h.s;\n}\n";
const KEPT_CAPTURE = KEPT_HEAD + "export function run(h: H): string {\n\tconst v = h.inner;\n\tconst f = (): string => v.s + \"!\";\n\tconst r = p(h);\n\treturn f() + r;\n}\n";

function cFiles(dir: string): string[] {
	const found: string[] = [];
	for (const e of readDir(dir)) {
		if (e.endsWith(".c")) found.push(e);
	}
	found.sort();
	return found;
}

function text(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : `UNREADABLE ${path}`;
}

function outsideRootKeptMismatch(name: string, m: string, states: string[]): string {
	const dir = `${root}/out/lowerOrder/${name}`;
	removeAll(dir);
	ensureDir(`${dir}/app`);
	ensureDir(`${dir}/lib`);
	writeFile(`${dir}/lib/h.ms`, KEPT_H);
	writeFile(`${dir}/lib/p.ms`, states[0]);
	writeFile(`${dir}/app/m.ms`, m);
	writeFile(`${dir}/app/app.ms`, KEPT_APP);
	let replay = "";
	for (let i = 1; i < states.length; i += 1) {
		writeFile(`${dir}/lib/p${i}.ms`, states[i]);
		replay = replay + `../lib/p${i}.ms ../lib/p.ms\n`;
	}
	writeFile(`${dir}/app/replay.txt`, replay);
	const app = `${dir}/app`;
	const warm = execFileResult(msc, ["build", "app.ms", "--hcr", "--watch-replay=replay.txt", "--emit=c"], app);
	if (warm.exitCode != 0) return `warm replay failed: ${warm.output}${warm.errorOutput}`;
	const debug = `${app}/out/debug`;
	for (let i = 0; i < states.length; i += 1) {
		writeFile(`${dir}/lib/p.ms`, states[i]);
		for (const f of cFiles(debug)) removeAll(`${debug}/${f}`);
		const cold = execFileResult(msc, ["build", "app.ms", "--hcr", "--emit=c"], app);
		if (cold.exitCode != 0) return `cold build of state ${i} failed: ${cold.output}${cold.errorOutput}`;
		for (const f of cFiles(debug)) {
			const warmC = text(`${debug}/watch${i}/${f}`);
			const coldC = text(`${debug}/${f}`);
			if (warmC != coldC) return `state ${i}: ${f} differs from a cold build:\n--- warm\n${warmC}\n--- cold\n${coldC}`;
		}
	}
	return "";
}

test "a kept session re-lowers a consumer when a private body it summarized starts writing the slot" {
	const bad = outsideRootKeptMismatch("keptWrite", KEPT_APPEND, [KEPT_P("const t = new Inner();\nt.s = \"y\";"), KEPT_P("h.s = h.s + \"!\";\nconst t = new Inner();")]);
	assert bad == "", bad;
}

test "a kept session re-lowers a consumer when a private body it summarized stops writing the slot" {
	const bad = outsideRootKeptMismatch("keptUnwrite", KEPT_APPEND, [KEPT_P("h.s = h.s + \"!\";\nconst t = new Inner();"), KEPT_P("const t = new Inner();\nt.s = \"y\";")]);
	assert bad == "", bad;
}

test "a kept session re-lowers a closure capture beside a call when the private body behind the call starts writing the slot" {
	const bad = outsideRootKeptMismatch("keptCapture", KEPT_CAPTURE, [KEPT_P("const t = new Inner();\nt.s = \"y\";"), KEPT_P("h.inner = new Inner();")]);
	assert bad == "", bad;
}
