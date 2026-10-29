// Cache lane: after every input change, a warm build must print what a build from an empty cache prints.
// Each scenario runs once per cache layer; nativeBuildBoundary.ms keeps the per-feature cache contracts.
import { argv, cwd, env, execFileCapture, exit, platform, spawn, ChildProcess } from "std/process";
import { ensureDir, exists, readDir, readFile, remove, removeAll, rename, symlink, writeFile } from "std/fs";

const windows = platform == "windows";
const macos = platform == "darwin";

interface Scenario {
	name: string;
	native: string;
	main: string;
	flags: string[];
	unchangedRebuilds: string;
	setup: (dir: string) => void;
	change: (dir: string) => void;
	env: (dir: string, changed: boolean) => string[][];
}

interface Case {
	scenario: Scenario;
	layer: string;
	dir: string;
	changed: boolean;
}

interface CaseResult {
	name: string;
	expected: string;
	actual: string;
}

function absolute(path: string): string {
	if (path.startsWith("/") || (path.length > 1 && path.charAt(1) == ":")) return path;
	return `${cwd()}/${path}`;
}

const params = argv.slice(1).filter((a: string): boolean => !a.startsWith("--"));
const compiler = absolute(params.length > 0 ? params[0] : "msc");
const only = env.get("MSCACHE_ONLY") == "" ? [] : env.get("MSCACHE_ONLY").split(",");
const root = makeRoot();
const results: CaseResult[] = [];
const ENV_NAMES = ["C_INCLUDE_PATH", "CPATH"];

function makeRoot(): string {
	const base = windows ? "C:/tmp" : "/tmp";
	ensureDir(base);
	let n = performance.now() as int64;
	while (exists(`${base}/msc-cache-lane-${n}`)) n = n + 1;
	const dir = `${base}/msc-cache-lane-${n}`;
	ensureDir(dir);
	return dir;
}

function need(ok: boolean, what: string): void {
	if (ok) return;
	console.log(`cache: setup step failed: ${what} (root ${root})`);
	exit(1);
}

function put(path: string, content: string): void {
	need(writeFile(path, content).ok, `write ${path}`);
}

function lateQuery(name: string): string {
	return `#if __has_include(${name})\n#include ${name}\n#else\n#define VALUE 11\n#endif\nint probeValue(void) { return VALUE; }\n`;
}

const NATIVE_MAIN = "@include(\"./api.h\");\n@compile(\"./native.c\");\nextern function probeValue(): int32;\nconsole.log(probeValue());\n";
const INCLUDES_VALUE = "#include \"value.h\"\nint probeValue(void) { return VALUE; }\n";
const nothing = (dir: string): void => {};
const noEnv = (dir: string, changed: boolean): string[][] => [];

function scenario(name: string, native: string, setup: (dir: string) => void, change: (dir: string) => void): Scenario {
	return { name, native, main: NATIVE_MAIN, flags: [], unchangedRebuilds: "0", setup, change, env: noEnv };
}

function moduleScenario(name: string, header: string, setup: (dir: string) => void, change: (dir: string) => void): Scenario {
	const s = scenario(name, "", setup, change);
	s.main = "@include(\"./value.h\");\nextern function probeValue(): int32;\nconsole.log(probeValue());\n";
	const own = s.setup;
	s.setup = (dir) => {
		put(`${dir}/value.h`, header);
		own(dir);
	};
	return s;
}

function scenarios(): Scenario[] {
	const list: Scenario[] = [];
	list.push(scenario("native source edit", "int probeValue(void) { return 11; }\n", nothing, (dir) => {
		put(`${dir}/native.c`, "int probeValue(void) { return 22; }\n");
	}));
	list.push(scenario("included header edit", INCLUDES_VALUE, (dir) => put(`${dir}/value.h`, "#define VALUE 11\n"), (dir) => {
		put(`${dir}/value.h`, "#define VALUE 22\n");
	}));
	list.push(scenario("transitive header edit", INCLUDES_VALUE, (dir) => {
		put(`${dir}/value.h`, "#include \"deep.h\"\n");
		put(`${dir}/deep.h`, "#define VALUE 11\n");
	}, (dir) => put(`${dir}/deep.h`, "#define VALUE 22\n")));
	list.push(scenario("header edited in place with its size and mtime restored", INCLUDES_VALUE, (dir) => {
		put(`${dir}/value.h`, "#define VALUE 11\n");
		put(`${dir}/stamp`, "");
		need(execFileCapture("touch", ["-r", `${dir}/stamp`, `${dir}/value.h`]).ok, "touch value.h");
	}, (dir) => {
		put(`${dir}/value.h`, "#define VALUE 22\n");
		need(execFileCapture("touch", ["-r", `${dir}/stamp`, `${dir}/value.h`]).ok, "touch value.h back");
	}));
	list.push(scenario("header replaced by rename", INCLUDES_VALUE, (dir) => put(`${dir}/value.h`, "#define VALUE 11\n"), (dir) => {
		put(`${dir}/next.h`, "#define VALUE 22\n");
		need(rename(`${dir}/next.h`, `${dir}/value.h`).ok, "rename next.h");
	}));
	list.push(scenario("queried header appears beside the source", lateQuery("\"late.h\""), nothing, (dir) => {
		put(`${dir}/late.h`, "#define VALUE 22\n");
	}));
	list.push(scenario("queried header appears in a new subdirectory", lateQuery("\"sub/late.h\""), nothing, (dir) => {
		ensureDir(`${dir}/sub`);
		put(`${dir}/sub/late.h`, "#define VALUE 22\n");
	}));
	list.push(scenario("queried header disappears", lateQuery("\"late.h\""), (dir) => put(`${dir}/late.h`, "#define VALUE 22\n"), (dir) => {
		remove(`${dir}/late.h`);
	}));
	list.push(scenario("queried header renamed away", lateQuery("\"late.h\""), (dir) => put(`${dir}/late.h`, "#define VALUE 22\n"), (dir) => {
		need(rename(`${dir}/late.h`, `${dir}/other.h`).ok, "rename late.h");
	}));
	const shadow = scenario("header appears in an earlier -I dir", INCLUDES_VALUE, (dir) => {
		ensureDir(`${dir}/inc1`);
		ensureDir(`${dir}/inc2`);
		put(`${dir}/inc2/value.h`, "#define VALUE 11\n");
	}, (dir) => put(`${dir}/inc1/value.h`, "#define VALUE 22\n"));
	shadow.flags = ["--passC=-Iinc1 -Iinc2"];
	list.push(shadow);
	for (const name of ENV_NAMES) {
		const appears = scenario(`queried header appears in a ${name} dir`, lateQuery("<late.h>"), (dir) => ensureDir(`${dir}/envinc`), (dir) => {
			put(`${dir}/envinc/late.h`, "#define VALUE 22\n");
		});
		appears.env = (dir, changed) => [[name, `${dir}/envinc`]];
		list.push(appears);
		const switched = scenario(`${name} switched to a dir with another header`, "#include <value.h>\nint probeValue(void) { return VALUE; }\n", (dir) => {
			ensureDir(`${dir}/a`);
			ensureDir(`${dir}/b`);
			put(`${dir}/a/value.h`, "#define VALUE 11\n");
			put(`${dir}/b/value.h`, "#define VALUE 22\n");
		}, nothing);
		switched.env = (dir, changed) => [[name, changed ? `${dir}/b` : `${dir}/a`]];
		list.push(switched);
	}
	list.push(scenario("queried header appears spelled in another case", lateQuery("\"late.h\""), nothing, (dir) => {
		put(`${dir}/Late.h`, "#define VALUE 22\n");
	}));
	const nfd = scenario("queried header appears in another Unicode normal form", lateQuery("\"\u00e9.h\""), nothing, (dir) => {
		put(`${dir}/e\u0301.h`, "#define VALUE 22\n");
	});
	nfd.unchangedRebuilds = "1";
	list.push(nfd);
	const computed = scenario("header queried through a macro appears", `#define LATE "late.h"\n${lateQuery("LATE")}`, nothing, (dir) => {
		put(`${dir}/late.h`, "#define VALUE 22\n");
	});
	computed.unchangedRebuilds = "1";
	list.push(computed);
	list.push(scenario("header named by a relative path appears", lateQuery("\"../late/late.h\""), nothing, (dir) => {
		ensureDir(`${dir}/late`);
		put(`${dir}/late/late.h`, "#define VALUE 22\n");
	}));
	list.push(moduleScenario("module-included header edit", "#include \"deep.h\"\nstatic inline int probeValue(void) { return VALUE; }\n", (dir) => {
		put(`${dir}/deep.h`, "#define VALUE 11\n");
	}, (dir) => put(`${dir}/deep.h`, "#define VALUE 22\n")));
	list.push(moduleScenario("header a module include queries appears", lateQuery("\"sub/late.h\"").replace("int probeValue", "static inline int probeValue"), nothing, (dir) => {
		ensureDir(`${dir}/sub`);
		put(`${dir}/sub/late.h`, "#define VALUE 22\n");
	}));
	if (!windows) {
		list.push(scenario("symlinked header retargeted", INCLUDES_VALUE, (dir) => {
			put(`${dir}/eleven.h`, "#define VALUE 11\n");
			put(`${dir}/twentytwo.h`, "#define VALUE 22\n");
			need(symlink(`${dir}/eleven.h`, `${dir}/value.h`).ok, "symlink value.h");
		}, (dir) => {
			remove(`${dir}/value.h`);
			need(symlink(`${dir}/twentytwo.h`, `${dir}/value.h`).ok, "retarget value.h");
		}));
		const linkedDir = scenario("symlinked include dir retargeted", "#include <value.h>\nint probeValue(void) { return VALUE; }\n", (dir) => {
			ensureDir(`${dir}/a`);
			ensureDir(`${dir}/b`);
			put(`${dir}/a/value.h`, "#define VALUE 11\n");
			put(`${dir}/b/value.h`, "#define VALUE 22\n");
			need(symlink(`${dir}/a`, `${dir}/inc`).ok, "symlink inc");
		}, (dir) => {
			remove(`${dir}/inc`);
			need(symlink(`${dir}/b`, `${dir}/inc`).ok, "retarget inc");
		});
		linkedDir.flags = ["--passC=-Iinc"];
		list.push(linkedDir);
	}
	if (macos) {
		const framework = scenario("framework header appears", lateQuery("<Late/late.h>"), (dir) => ensureDir(`${dir}/fw`), (dir) => {
			ensureDir(`${dir}/fw/Late.framework/Headers`);
			put(`${dir}/fw/Late.framework/Headers/late.h`, "#define VALUE 22\n");
		});
		framework.flags = ["--passC=-Ffw"];
		list.push(framework);
	}
	return list;
}

function withEnv(c: Case, run: () => number): number {
	const pairs = c.scenario.env(c.dir, c.changed);
	for (const pair of pairs) env.set(pair[0], pair[1]);
	const code = run();
	for (const pair of pairs) env.delete(pair[0]);
	return code;
}

function build(c: Case, label: string, output: string, extra: string[]): number {
	const args = ["build", "main.ms", `--output=${output}`];
	if (!windows) args.push("--cc=clang");
	for (const flag of c.scenario.flags) args.push(flag);
	for (const flag of extra) args.push(flag);
	return withEnv(c, () => {
		const r = execFileCapture(compiler, args, c.dir);
		put(`${c.dir}/${label}.log`, r.ok ? r.value : r.error.output + r.error.errorOutput + r.error.message);
		return r.ok ? 0 : (r.error.exitCode != 0 ? r.error.exitCode : -1);
	});
}

function printed(c: Case, output: string, code: number): string {
	if (code != 0) return `build exit ${code}`;
	const r = execFileCapture(`${c.dir}/${output}`, []);
	return r.ok ? r.value.trim() : "run failed";
}

function recompiledObjects(c: Case, label: string): string {
	const log = readFile(`${c.dir}/${label}.log`);
	if (!log.ok) return "no log";
	let n = 0;
	for (const line of log.value.split("\n")) {
		const compileLine = line.indexOf("  cc ", 0) >= 0 || line.indexOf("  @compile ", 0) >= 0;
		const reused = line.indexOf("cached", 0) >= 0 || line.indexOf("(stored)", 0) >= 0;
		if (compileLine && line.indexOf(" → ", 0) >= 0 && !reused) n = n + 1;
	}
	return `${n}`;
}

function warmOutput(c: Case, step: string): string {
	if (c.layer == "store") removeAll(`${c.dir}/out`);
	return c.layer == "local" ? `probe-${step}` : "probe";
}

function waitTwoSeconds(): void {
	const until = performance.now() + 2000;
	while (performance.now() < until) execFileCapture(compiler, ["--version"]);
}

function selected(s: Scenario): boolean {
	return only.length == 0 || only.some((name) => s.name.includes(name));
}

env.set("MSC_GLOBAL_CACHE_DIR", `${root}/global`);
env.delete("MSC_CACHE_DIR");
env.delete("MSC_NO_GLOBAL_CACHE");
for (const name of ENV_NAMES) env.delete(name);

const cases: Case[] = [];
let n = 0;
for (const s of scenarios()) {
	if (!selected(s)) continue;
	for (const layer of ["project", "local", "store"]) {
		const dir = `${root}/${n}-${layer}`;
		n = n + 1;
		ensureDir(dir);
		put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
		put(`${dir}/api.h`, "int probeValue(void);\n");
		put(`${dir}/main.ms`, s.main);
		if (s.native != "") put(`${dir}/native.c`, s.native);
		s.setup(dir);
		cases.push({ scenario: s, layer, dir, changed: false });
	}
}
waitTwoSeconds();
for (const c of cases) need(build(c, "baseline", "probe", []) == 0, `${c.scenario.name} (${c.layer}) baseline`);
waitTwoSeconds();
waitTwoSeconds();
for (const c of cases) {
	const output = warmOutput(c, "unchanged");
	need(build(c, "unchanged", output, ["--verbose"]) == 0, `${c.scenario.name} (${c.layer}) unchanged`);
	results.push({ name: `${c.layer}: ${c.scenario.name}: unchanged rebuilds`, expected: c.scenario.unchangedRebuilds, actual: recompiledObjects(c, "unchanged") });
}
for (const c of cases) {
	c.scenario.change(c.dir);
	c.changed = true;
}
for (const c of cases) {
	const output = warmOutput(c, "changed");
	const warm = printed(c, output, build(c, "changed", output, []));
	env.set("MSC_CACHE_DIR", `${c.dir}/truth-cache`);
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	const truthCode = build(c, "truth", "truth", []);
	env.delete("MSC_CACHE_DIR");
	env.delete("MSC_NO_GLOBAL_CACHE");
	const truth = printed(c, "truth", truthCode);
	results.push({ name: `${c.layer}: ${c.scenario.name}`, expected: truth, actual: warm });
}

interface EditLoop {
	name: string;
	mode: string;
	flags: string[];
	modules: string[];
	edited: string[];
}

const EDIT_STEPS = 4;

function editLoops(): EditLoop[] {
	return [
		{ name: "edited module keeps one local version", mode: "debug", flags: [], modules: ["editedA"], edited: ["editedA"] },
		{ name: "edited module keeps one local version in release", mode: "release", flags: ["--release"], modules: ["editedA"], edited: ["editedA"] },
		{ name: "each edited module keeps one local version, an untouched one keeps its own", mode: "debug", flags: [], modules: ["editedA", "editedB", "steadyC"], edited: ["editedA", "editedB"] },
	];
}

function moduleSource(module: string, value: number): string {
	return `export function ${module}Value(): int32 { return ${value}; }\n`;
}

function moduleMain(modules: string[]): string {
	let text = "";
	const parts: string[] = [];
	for (const m of modules) {
		text = `${text}import { ${m}Value } from "./${m}";\n`;
		parts.push("${" + m + "Value()}");
	}
	return text + "console.log(`" + parts.join(",") + "`);\n";
}

function localVersions(dir: string, mode: string, module: string): string {
	const cacheDir = `${dir}/out/${mode}/.cache`;
	let c = 0;
	let d = 0;
	let cfp = 0;
	for (const entry of readDir(cacheDir)) {
		if (entry.indexOf(`${module}_x_ms.`, 0) < 0) continue;
		if (entry.endsWith(".c")) c = c + 1;
		if (entry.endsWith(".d")) d = d + 1;
		if (entry.endsWith(".o.cfp")) cfp = cfp + 1;
	}
	return `c=${c} d=${d} cfp=${cfp}`;
}

function cacheKb(cacheDir: string): string {
	const size = execFileCapture("du", ["-sk", cacheDir]);
	return size.ok ? size.value.split("\t")[0] : "unmeasured";
}

function backdate(cacheDir: string): boolean {
	if (windows) return false;
	return execFileCapture("find", [cacheDir, "-type", "f", "-exec", "touch", "-t", "200001010000", "{}", "+"]).ok;
}

function runEditLoop(loop: EditLoop, index: number): void {
	const dir = `${root}/loop-${index}`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/main.ms`, moduleMain(loop.modules));
	for (const m of loop.modules) put(`${dir}/${m}.ms`, moduleSource(m, 0));
	const buildArgs = (output: string): string[] => {
		const args = ["build", "main.ms", `--output=${output}`];
		if (!windows) args.push("--cc=clang");
		for (const flag of loop.flags) args.push(flag);
		return args;
	};
	const args = buildArgs("probe");
	need(execFileCapture(compiler, args, dir).ok, `${loop.name} baseline`);
	const warm: string[] = [];
	const expected: string[] = [];
	let liveKb = "unmeasured";
	let backdated = false;
	for (let step = 1; step <= EDIT_STEPS; step++) {
		if (step == EDIT_STEPS) {
			liveKb = cacheKb(`${dir}/out/${loop.mode}/.cache`);
			backdated = backdate(`${dir}/out/${loop.mode}/.cache`);
		}
		for (const m of loop.edited) put(`${dir}/${m}.ms`, moduleSource(m, step));
		need(execFileCapture(compiler, args, dir).ok, `${loop.name} step ${step}`);
		const r = execFileCapture(`${dir}/probe`, []);
		warm.push(r.ok ? r.value.trim() : "run failed");
		expected.push(loop.modules.map((m) => loop.edited.includes(m) ? `${step}` : "0").join(","));
	}
	results.push({ name: `local: ${loop.name}: output after each edit`, expected: expected.join(" "), actual: warm.join(" ") });
	console.log(`${loop.name}: local cache ${liveKb} KB before edit ${EDIT_STEPS} (versions inside the live window), ${cacheKb(`${dir}/out/${loop.mode}/.cache`)} KB after it (earlier versions unused for hours)`);
	if (backdated) {
		const versions = loop.modules.map((m) => `${m} ${localVersions(dir, loop.mode, m)}`);
		results.push({ name: `local: ${loop.name}: versions kept`, expected: loop.modules.map((m) => `${m} c=${loop.edited.includes(m) ? EDIT_STEPS + 1 : 1} d=1 cfp=1`).join(", "), actual: versions.join(", ") });
	}
	env.set("MSC_CACHE_DIR", `${dir}/truth-cache`);
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	const truth = execFileCapture(compiler, buildArgs("truth"), dir);
	env.delete("MSC_CACHE_DIR");
	env.delete("MSC_NO_GLOBAL_CACHE");
	const cold = execFileCapture(`${dir}/truth`, []);
	const coldText = truth.ok && cold.ok ? cold.value.trim() : "truth build failed";
	results.push({ name: `local: ${loop.name}: last warm build equals a cold build`, expected: coldText, actual: warm[warm.length - 1] });
}

let loopIndex = 0;
for (const loop of editLoops()) {
	if (only.length == 0 || only.some((name) => loop.name.includes(name))) runEditLoop(loop, loopIndex);
	loopIndex = loopIndex + 1;
}

const RIVAL_ROUNDS = 10;
const RIVAL_SLEEP_SECONDS = 2;
const RIVALS = "concurrent builds of two programs sharing a module that emits different C";

function rivalSource(program: string): string {
	return `import { from${program} } from "./shared";\nimport { slow${program}Value } from "./slow${program}";\n` + "console.log(`${from" + program + "()}:${slow" + program + "Value()}`);\n";
}

function rivalCompiler(dir: string): string {
	ensureDir(`${dir}/bin`);
	put(`${dir}/bin/slow`, "none");
	put(`${dir}/bin/clang`, `#!/bin/sh\ncase "$*" in *"$(cat "$(dirname "$0")/slow")"*) sleep ${RIVAL_SLEEP_SECONDS};; esac\nexec clang "$@"\n`);
	need(execFileCapture("chmod", ["+x", `${dir}/bin/clang`]).ok, "rival compiler executable");
	return `${dir}/bin/clang`;
}

function startRival(dir: string, cc: string, program: string): ChildProcess | null {
	const started = spawn(compiler, ["build", `prog${program}.ms`, `--output=prog${program}`, `--cc=${cc}`], { cwd: dir });
	return started.ok ? started.value : null;
}

function finishRival(dir: string, child: ChildProcess | null, program: string): string {
	if (child == null) return "build did not start";
	const status = child.wait(300000);
	if (!status.ok) return "build timed out";
	if (status.value.code != 0) return `build failed (exit ${status.value.code}) ${child.takeStderr().slice(0, 160)}`;
	const ran = execFileCapture(`${dir}/prog${program}`, []);
	return ran.ok ? ran.value.trim() : "run failed";
}

function runRivals(): void {
	if (windows) return;
	const dir = `${root}/rivals`;
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/shared.ms`, "export function fromA(): int32 { return 1; }\nexport function fromB(): int32 { return 2; }\n");
	for (const program of ["A", "B"]) put(`${dir}/prog${program}.ms`, rivalSource(program));
	const cc = rivalCompiler(dir);
	put(`${dir}/slowA.ms`, moduleSource("slowA", -1));
	put(`${dir}/slowB.ms`, moduleSource("slowB", -1));
	need(finishRival(dir, startRival(dir, cc, "A"), "A") == "1:-1", `${RIVALS}: seed build`);
	const expected: string[] = [];
	const actual: string[] = [];
	for (let round = 0; round < RIVAL_ROUNDS; round++) {
		const slow = round % 2 == 0 ? "A" : "B";
		const fast = round % 2 == 0 ? "B" : "A";
		put(`${dir}/slowA.ms`, moduleSource("slowA", round));
		put(`${dir}/slowB.ms`, moduleSource("slowB", round));
		put(`${dir}/bin/slow`, `slow${slow}_x_ms`);
		backdate(`${dir}/out/debug/.cache`);
		const slowChild = startRival(dir, cc, slow);
		execFileCapture("sleep", ["0.4"]);
		const fastChild = startRival(dir, cc, fast);
		const slowText = finishRival(dir, slowChild, slow);
		const fastText = finishRival(dir, fastChild, fast);
		for (const program of ["A", "B"]) {
			expected.push(`${program == "A" ? 1 : 2}:${round}`);
			actual.push(program == slow ? slowText : fastText);
		}
	}
	results.push({ name: `local: ${RIVALS}: every build links and prints its own value`, expected: expected.join(" "), actual: actual.join(" ") });
}

if (only.length == 0 || only.some((name) => RIVALS.includes(name))) runRivals();

const CHECKOUTS = "two checkouts of one project at different paths";

function checkoutBuild(dir: string, trim: boolean, offset: int32 = 4100): string[] {
	ensureDir(dir);
	put(`${dir}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${dir}/a.ms`, `export function fa(x: int32): int32 { return x + ${offset}; }\n`);
	put(`${dir}/main.ms`, "import { fa } from \"./a\";\nconsole.log(`${fa(41)}`);\n");
	const args = ["build", "main.ms", "--output=app", "--verbose", "--cc=clang"];
	if (trim) args.push("--trimpath");
	const built = execFileCapture(compiler, args, dir);
	if (!built.ok) return ["build failed", "0"];
	let restored = 0;
	for (const line of built.value.split("\n")) {
		if (line.indexOf("  stored ", 0) >= 0 && line.indexOf("/proj/", 0) >= 0) restored = restored + 1;
	}
	const ran = execFileCapture(`${dir}/app`, []);
	return [ran.ok ? ran.value.trim() : "run failed", `${restored}`];
}

function runCheckouts(): void {
	if (windows) return;
	for (const trim of [true, false]) {
		const mode = trim ? "trimpath" : "default";
		const first = checkoutBuild(`${root}/checkouts-${mode}/a/proj`, trim);
		const second = checkoutBuild(`${root}/checkouts-${mode}/b/proj`, trim);
		results.push({ name: `store: ${CHECKOUTS}, ${mode}: the second restores the project modules the first published and prints the same`, expected: `4141 4141 restored ${trim ? 2 : 0}`, actual: `${first[0]} ${second[0]} restored ${second[1]}` });
	}
}

if (only.length == 0 || only.some((name) => CHECKOUTS.includes(name))) runCheckouts();

const LOST = "a store object lost beside its manifest";

function runLostObject(): void {
	if (windows) return;
	const base = `${root}/lost`;
	const first = checkoutBuild(`${base}/a/proj`, true, 4200);
	const swept = execFileCapture("find", [`${root}/global/store`, "-type", "f", "-name", "*.o", "-print", "-delete"]);
	const lost = swept.ok ? swept.value.split("\n").filter((line: string): boolean => line != "").length : -1;
	const second = checkoutBuild(`${base}/b/proj`, true, 4200);
	const third = checkoutBuild(`${base}/c/proj`, true, 4200);
	results.push({ name: `store: ${LOST}: the next build publishes the object again and the one after restores it`, expected: `4241 4241 4241 lost every object, restored 0 2`, actual: `${first[0]} ${second[0]} ${third[0]} lost ${lost >= 2 ? "every object" : `${lost}`}, restored ${second[1]} ${third[1]}` });
}

if (only.length == 0 || only.some((name) => LOST.includes(name))) runLostObject();

let failures = 0;
console.log(`root ${root}`);
for (const r of results) {
	const pass = r.expected == r.actual;
	if (!pass) failures = failures + 1;
	console.log(`${pass ? "pass" : "FAIL"}  ${r.name}  expected=${r.expected} actual=${r.actual}`);
}
console.log(`cache: ${results.length - failures} pass, ${failures} fail, ${cases.length} cases`);
if (failures == 0 && env.get("MSC_CACHE_LANE_KEEP_ROOT") == "") removeAll(root);
exit(failures == 0 ? 0 : 1);
