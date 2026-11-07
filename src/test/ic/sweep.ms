// Incremental verify sweep: msc run --target=raiser src/test/ic/sweep.ms, from the recompiler root.
// Copies a project, then drives one warm watch session under MSC_IC_VERIFY=1 through a private body
// edit, its revert, an exported addition and its revert of every module, so each warm build is
// compared with a cold build of the same sources. Hand-written cases live in cases/; this finds the
// ones nobody wrote. Env: MSC, SWEEP_DIR=<project dir, relative to the root>, SWEEP_ENTRY (main.ms),
// SWEEP_MODULES=<comma list of module paths relative to SWEEP_DIR> to edit only those.
import { execFileResult, ExecFileResult, exit, env, cwd } from "std/process";
import { readFile, writeFile, readDir, exists, isDir, ensureDir, removeAll } from "std/fs";

function slashes(p: string): string {
	return p.replaceAll("\\", "/");
}

const ROOT = slashes(cwd());

function resolveMsc(): string {
	const explicit = slashes(env.get("MSC"));
	if (explicit != "") return explicit.startsWith("/") || explicit.indexOf(":") >= 0 || explicit.indexOf("/") < 0 ? explicit : `${ROOT}/${explicit}`;
	if (exists("./msc") || exists("./msc.exe")) return `${ROOT}/msc`;
	return "msc";
}

function both(r: ExecFileResult): string {
	return r.output + r.errorOutput;
}

function read(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : "";
}

function put(path: string, content: string): void {
	const slash = path.lastIndexOf("/");
	if (slash > 0) ensureDir(path.slice(0, slash));
	if (!writeFile(path, content).ok) {
		console.log(`FAIL icSweep: cannot write ${path}`);
		exit(1);
	}
}

function modulesUnder(dir: string, rel: string, out: string[]): void {
	for (const name of readDir(rel == "" ? dir : `${dir}/${rel}`)) {
		const path = rel == "" ? name : `${rel}/${name}`;
		if (name == "out" && rel == "") continue;
		if (isDir(`${dir}/${path}`)) modulesUnder(dir, path, out);
		else if (name.endsWith(".ms")) out.push(path);
	}
}

interface SweepStep {
	module: string;
	kind: string;
}

const MSC = resolveMsc();
const source = env.get("SWEEP_DIR");
const entry = env.get("SWEEP_ENTRY") == "" ? "main.ms" : env.get("SWEEP_ENTRY");
if (source == "" || !isDir(`${ROOT}/${source}`)) {
	console.log(`FAIL icSweep: SWEEP_DIR must name a project directory under ${ROOT}`);
	exit(1);
}
env.set("NO_COLOR", "1");
env.set("MSC_NO_GLOBAL_CACHE", "1");
const dir = `${ROOT}/out/icsweep/${source.replaceAll("/", "_")}`;
removeAll(dir);
const work = `${dir}/work`;
ensureDir(dir);
const copied = execFileResult("cp", ["-R", `${ROOT}/${source}`, work]);
if (copied.exitCode != 0) {
	console.log(`FAIL icSweep: cannot copy ${source}: ${both(copied)}`);
	exit(1);
}

const modules: string[] = [];
modulesUnder(work, "", modules);
modules.sort();
const chosen = env.get("SWEEP_MODULES") == "" ? [] as string[] : env.get("SWEEP_MODULES").split(",");
for (const name of chosen) {
	if (!modules.includes(name)) {
		console.log(`FAIL icSweep: SWEEP_MODULES names ${name}, which is no module of ${source}`);
		exit(1);
	}
}
if (chosen.length > 0) {
	modules.length = 0;
	for (const name of chosen) modules.push(name);
}
const steps: SweepStep[] = [];
let replay = "";
for (const module of modules) {
	const original = read(`${work}/${module}`);
	const base = original.endsWith("\n") ? original : original + "\n";
	const edits: string[][] = [
		["body", base + "const __icSweepBody: int32 = 1;\n"],
		["body-revert", original],
		["iface", base + "export const __icSweepIface: int32 = 1;\n"],
		["iface-revert", original],
	];
	for (const [kind, text] of edits) {
		const stepFile = `${dir}/steps/${steps.length + 1}/${module}`;
		put(stepFile, text);
		replay = replay + `${stepFile} ${module}\n`;
		steps.push({ module, kind });
	}
}
put(`${dir}/replay.txt`, replay);
env.set("MSC_CACHE_DIR", `${dir}/cache`);
env.set("MSC_IC_VERIFY", "1");
const watched = execFileResult(MSC, ["build", entry, "--hcr", `--watch-replay=${dir}/replay.txt`, "--emit=c"], work);
env.delete("MSC_IC_VERIFY");
put(`${dir}/watch.log`, both(watched));

const builds = steps.length + 1;
const verdicts: string[] = [];
for (let k = 0; k < builds; k += 1) verdicts.push("");
for (const line of watched.output.split("\n")) {
	const m = line.startsWith("watch: verify build ") ? line.slice(20, line.length) : "";
	if (m == "") continue;
	const space = m.indexOf(" ");
	const colon = m.indexOf(":");
	const end = space >= 0 && space < colon ? space : colon;
	const k = parseInt(m.slice(0, end));
	if (k >= 0 && k < builds && verdicts[k] == "") verdicts[k] = m.slice(end, m.length).trim();
}
let equal = 0;
const problems: string[] = [];
for (let k = 0; k < builds; k += 1) {
	const what = k == 0 ? "first build" : `${steps[k - 1].kind} of ${steps[k - 1].module}`;
	if (verdicts[k].startsWith(":")) equal += 1;
	else if (verdicts[k] == "") problems.push(`build ${k} (${what}): no verify result; the build failed or stopped (${dir}/watch.log)`);
	else problems.push(`build ${k} (${what}): ${verdicts[k]}`);
}
for (const p of problems) console.log(`FAIL ${source}: ${p}`);
console.log(`icSweep ${source}: ${modules.length} modules, ${builds} builds, ${equal} equal a cold build, ${problems.length} not`);
if (problems.length > 0) exit(1);
