// Cache lane: after every input change, a warm build must print what a build from an empty cache prints.
// Each scenario runs once per cache layer; nativeBuildBoundary.ms keeps the per-feature cache contracts.
import { argv, cwd, env, execFileCapture, exit, platform } from "std/process";
import { ensureDir, exists, readFile, remove, removeAll, rename, symlink, writeFile } from "std/fs";

const windows = platform == "windows";
const macos = platform == "macos";

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
