// A prelude pack or std graph seed written for one target is a miss for every other target. The
// std closure and the parsed prelude follow the `when` blocks in std, which read --os, --cpu, --gc,
// the build mode and -d flags, so a host, an `--os=solana` and an `--os=bare` run each read only
// what their own target wrote to $HOME/.metascript/cache/prelude.
//
// WHY A SUBPROCESS: the observable is what `msc check` and `msc build` report after another target
// ran against the same cache, which one process cannot stage twice. The compiler under test is
// $MSC, else `./msc`; every cell gets a private HOME, so the toolchains are named explicitly:
// `--cc=clang` for host builds and $MSC_SBF_CLANG for `--os=solana`.
//
// RED PRE-FIX: solana then host failed with 141 type errors, host then solana read 55 modules
// where solana alone reads 40, and a host build then an `--os=solana` build failed to compile
// runtime/crypto/hash.c. GREEN POST-FIX: GUARD-OK.

import { execFileResult, ExecFileResult, cwd, exit, env, findOnPath } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardPreludePackTarget`;
const realHome = env.get("HOME");

let failed = 0;
let hostModules: int32 = 0;
let solanaModules: int32 = 0;
let bareModules: int32 = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function fileOf(target: string): string {
	if (target == "solana") return "chain.ms";
	if (target == "bare") return "bare.ms";
	return "host.ms";
}

function osArgs(target: string): string[] {
	if (target == "solana") return ["--os=solana"];
	if (target == "bare") return ["--os=bare"];
	return [];
}

function modulesAlone(target: string): int32 {
	if (target == "solana") return solanaModules;
	if (target == "bare") return bareModules;
	return hostModules;
}

function privateHome(label: string): string {
	const home = `${dir}/home-${label}`;
	removeAll(home);
	ensureDir(`${home}/.metascript/cache`);
	return home;
}

function newerVersion(a: string, b: string): boolean {
	const ap = a.slice(1, a.length).split(".");
	const bp = b.slice(1, b.length).split(".");
	let i = 0;
	while (i < ap.length && i < bp.length) {
		const x = ap[i].parseInt();
		const y = bp[i].parseInt();
		if (x != y) return x > y;
		i = i + 1;
	}
	return ap.length > bp.length;
}

function sbfClang(): string {
	const named = env.get("MSC_SBF_CLANG");
	if (named != "") return named;
	const cacheRoot = `${realHome}/.cache/solana`;
	if (realHome == "" || !exists(cacheRoot)) return "";
	let best = "";
	let bestName = "";
	for (const entry of readDir(cacheRoot)) {
		const name = entry.endsWith("/") ? entry.slice(0, entry.length - 1) : entry;
		const candidate = `${cacheRoot}/${name}/platform-tools/llvm/bin/clang`;
		if (name == "" || !exists(candidate)) continue;
		if (bestName == "" || newerVersion(name, bestName)) {
			best = candidate;
			bestName = name;
		}
	}
	return best;
}

function runMsc(home: string, args: string[]): ExecFileResult {
	env.set("HOME", home);
	const r = execFileResult(msc, args, dir);
	if (realHome != "") env.set("HOME", realHome);
	else env.delete("HOME");
	return r;
}

function targetArgs(command: string, target: string, extra: string[]): string[] {
	const all: string[] = [command, fileOf(target)];
	for (const a of osArgs(target)) all.push(a);
	for (const a of extra) all.push(a);
	return all;
}

function moduleCount(text: string): int32 {
	const marker = "no type errors in ";
	const at = text.indexOf(marker);
	if (at < 0) return -1;
	let i = at + marker.length;
	let n: int32 = 0;
	while (i < text.length) {
		const c = text.charCodeAt(i);
		if (c < 48 || c > 57) break;
		n = n * 10 + (c - 48);
		i = i + 1;
	}
	return n;
}

function firstLines(r: ExecFileResult): string {
	const text = `${r.errorOutput}${r.output}`;
	for (const line of text.split("\n")) {
		if (line.includes("error")) return line.length > 240 ? line.slice(0, 240) : line;
	}
	return text.length > 240 ? text.slice(0, 240) : text;
}

function depsIn(dir: string): int32 {
	if (!exists(dir)) return 0;
	let n: int32 = 0;
	for (const entry of readDir(dir)) {
		if (entry.endsWith(".deps")) n = n + 1;
		else if (entry.endsWith("/")) n = n + depsIn(`${dir}/${entry.slice(0, entry.length - 1)}`);
	}
	return n;
}

function seedCount(home: string): int32 {
	return depsIn(`${home}/.metascript/cache/prelude`);
}

function checkAlone(target: string): int32 {
	const r = runMsc(privateHome(`alone-${target}`), targetArgs("check", target, []));
	const n = r.exitCode == 0 ? moduleCount(`${r.errorOutput}${r.output}`) : -1;
	if (n <= 0) report(`${target} alone does not check: ${firstLines(r)}`);
	return n;
}

function checkOrder(first: string, second: string): void {
	const home = privateHome(`${first}-${second}`);
	const order: string[] = [first, second, first];
	let step = 0;
	for (const target of order) {
		const r = runMsc(home, targetArgs("check", target, []));
		const n = r.exitCode == 0 ? moduleCount(`${r.errorOutput}${r.output}`) : -1;
		if (n != modulesAlone(target)) {
			report(`${first} then ${second}, step ${step + 1}: check of ${target} saw ${n} module(s), alone it sees ${modulesAlone(target)}: ${firstLines(r)}`);
		}
		if (step == 0 && seedCount(home) == 0) report(`${first}: no std graph seed was written, the guard measures nothing`);
		step = step + 1;
	}
}

function checkDefineAxes(): void {
	const home = privateHome("defines");
	const variants: string[][] = [[], ["-d:probeFlag"], ["--release"]];
	let want: int32 = 1;
	for (const extra of variants) {
		const r = runMsc(home, targetArgs("check", "host", extra));
		if (r.exitCode != 0 || moduleCount(`${r.errorOutput}${r.output}`) != hostModules) {
			report(`host check with [${extra.join(" ")}] saw ${moduleCount(`${r.errorOutput}${r.output}`)} module(s), alone it sees ${hostModules}: ${firstLines(r)}`);
		}
		if (seedCount(home) != want) report(`host check with [${extra.join(" ")}]: ${seedCount(home)} std graph seed(s) in the cache, want ${want}: a define the std when-blocks read is not part of the key`);
		want = want + 1;
	}
}

function buildOrder(first: string, second: string, hostCc: string): void {
	const home = privateHome(`build-${first}-${second}`);
	let step = 0;
	for (const target of [first, second]) {
		const extra: string[] = target == "host" ? ["--gc=drc", `--cc=${hostCc}`, `--output=${dir}/prog-${first}-${second}-host`] : [`--output=${dir}/prog-${first}-${second}.so`];
		const r = runMsc(home, targetArgs("build", target, extra));
		if (r.exitCode != 0) report(`${first} build then ${second} build, step ${step + 1}: the ${target} build failed: ${firstLines(r)}`);
		step = step + 1;
	}
}

env.delete("MSC_NO_PRELUDE_PACK");
env.delete("MSC_NO_GLOBAL_CACHE");

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/host.ms`, "import { cwd } from \"std/process\";\nimport { platform } from \"std/os\";\nconsole.log(cwd(), platform());\n");
writeFile(`${dir}/chain.ms`, "import { logU64, instructionData } from \"std/solana\";\nfunction main(): void { logU64(instructionData().length as uint64); }\nmain();\n");
writeFile(`${dir}/bare.ms`, "function answer(): int32 { return 42; }\nanswer();\n");

hostModules = checkAlone("host");
solanaModules = checkAlone("solana");
bareModules = checkAlone("bare");
if (failed != 0) exit(1);
if (hostModules == solanaModules || hostModules == bareModules || solanaModules == bareModules) {
	report(`the three targets read ${hostModules}, ${solanaModules} and ${bareModules} modules: the guard cannot tell their graphs apart`);
	exit(1);
}

checkOrder("host", "solana");
checkOrder("solana", "host");
checkOrder("host", "bare");
checkOrder("bare", "host");
checkOrder("solana", "bare");
checkDefineAxes();

const clang = sbfClang();
const hostCc = findOnPath("clang") != "" ? "clang" : "";
if (clang == "" || hostCc == "") {
	console.log(`GUARD-NOTE build cells not run: ${clang == "" ? "no SBF toolchain" : "no clang on PATH"} on this host`);
} else {
	env.set("MSC_SBF_CLANG", clang);
	buildOrder("solana", "host", hostCc);
	buildOrder("host", "solana", hostCc);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
