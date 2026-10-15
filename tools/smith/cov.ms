import { cwd, env, execFileResult, findOnPath } from "std/process";
import { ensureDir, exists, readDir, readFile, realpath, removeAll, writeFile } from "std/fs";
import { djb2, hashToHex } from "std/hash";
import { Features, format, swarm } from "./features";
import { generate } from "./gen";
import { identify, programName } from "./drive";

const PIPELINE_DIRS: string[] = ["lexer", "parser", "ast", "binder", "module", "checker", "monomorphize", "transform", "analyzer", "codegen", "raiser"];

struct Row {
	file: string;
	regions: int32;
	missedRegions: int32;
	functions: int32;
	missedFunctions: int32;
	branches: int32;
	missedBranches: int32;
}

function fail(msg: string): int32 {
	console.log("smith: " + msg);
	return 2;
}

function llvmTool(name: string): string[] {
	return findOnPath("xcrun") != "" ? ["xcrun", name] : [name];
}

function run(cmd: string[], dir: string): Result<string, string> {
	const r = execFileResult(cmd[0], cmd.slice(1, cmd.length), dir);
	if (!r.started) { return Result.err(cmd[0] + " did not start"); }
	if (r.exitCode != 0) { return Result.err(cmd.join(" ") + " exited " + String(r.exitCode) + ": " + r.errorOutput.trim()); }
	return Result.ok(r.output);
}

function fields(line: string): string[] {
	const out: string[] = [];
	for (const part of line.split(" ")) {
		if (part != "") { out.push(part); }
	}
	return out;
}

export function parseReport(text: string): Row[] {
	const rows: Row[] = [];
	for (const line of text.split("\n")) {
		const f = fields(line);
		if (f.length != 13 || f[0] == "Filename" || f[0] == "TOTAL") { continue; }
		rows.push({
			file: f[0],
			regions: f[1].parseInt() as int32,
			missedRegions: f[2].parseInt() as int32,
			functions: f[4].parseInt() as int32,
			missedFunctions: f[5].parseInt() as int32,
			branches: f[10].parseInt() as int32,
			missedBranches: f[11].parseInt() as int32,
		});
	}
	return rows;
}

export function cacheStem(file: string): string {
	const base = file.slice(file.lastIndexOf("/") + 1, file.length);
	const dot = base.indexOf(".");
	return dot < 0 ? base : base.slice(0, dot);
}

export function moduleOf(stem: string, sources: string[]): string {
	let found = "";
	for (const s of sources) {
		const encoded = "_d_" + s.replaceAll("/", "_d_").replaceAll(".", "_x_");
		if (!encoded.endsWith(stem) && !stem.endsWith(encoded)) { continue; }
		if (found != "") { return ""; }
		found = s;
	}
	return found;
}

function ratio(total: int32, missed: int32): string {
	return String(total - missed) + "/" + String(total);
}

export function formatRows(rows: Row[], sources: string[]): string {
	const lines: string[] = [];
	let regions = 0;
	let missedRegions = 0;
	let branches = 0;
	let missedBranches = 0;
	for (const r of rows) {
		const m = moduleOf(cacheStem(r.file), sources);
		if (m == "") { continue; }
		lines.push(m + "  regions " + ratio(r.regions, r.missedRegions) + "  branches " + ratio(r.branches, r.missedBranches) + "  functions " + ratio(r.functions, r.missedFunctions));
		regions += r.regions;
		missedRegions += r.missedRegions;
		branches += r.branches;
		missedBranches += r.missedBranches;
	}
	lines.sort();
	lines.push("pipeline total  regions " + ratio(regions, missedRegions) + "  branches " + ratio(branches, missedBranches));
	return lines.join("\n") + "\n";
}

function compilerSources(root: string): Result<string[], string> {
	const listed = run(["git", "-C", root, "ls-files", "src"], root);
	if (!listed.ok) { return Result.err(listed.error); }
	const out: string[] = [];
	for (const line of listed.value.split("\n")) {
		if (line.endsWith(".ms") && PIPELINE_DIRS.includes(line.split("/")[1])) { out.push(line); }
	}
	return Result.ok(out);
}

export function coverSeeds(first: uint64, count: int32, base: Features, swarmed: boolean, given: string): int32 {
	const root = cwd().replaceAll("\\", "/");
	if (!exists(given)) { return fail("no instrumented compiler at " + given); }
	const instrumented = realpath(given).replaceAll("\\", "/");
	const source = readFile(instrumented + ".src");
	if (!source.ok) { return fail("write the commit " + instrumented + " was built from into " + instrumented + ".src; a report must name the compiler it measured"); }
	const sources = compilerSources(root);
	if (!sources.ok) { return fail(sources.error); }
	const vector = base.format() + (swarmed ? " swarm" : "");
	const dir = root + "/out/smith/cov/seeds" + String(first) + "-" + String(count) + "-" + hashToHex(djb2(vector)).slice(0, 8);
	removeAll(dir);
	ensureDir(dir + "/programs");
	env.set("LLVM_PROFILE_FILE", dir + "/batch-%m.profraw");
	env.set("MSC_NO_GLOBAL_CACHE", "1");
	let emitted = 0;
	for (let i = 0; i < count; i++) {
		const seed = first + (i as uint64);
		const f = swarmed ? base.swarm(seed) : base;
		const file = dir + "/programs/" + programName(seed, f) + ".ms";
		writeFile(file, generate(seed, f));
		const r = execFileResult(instrumented, ["build", file, "--emit=c", "--emit-jobs=1"], dir);
		if (r.started && r.exitCode == 0) { emitted++; }
	}
	env.set("LLVM_PROFILE_FILE", "");
	env.set("MSC_NO_GLOBAL_CACHE", "");
	const raws: string[] = [];
	for (const name of readDir(dir)) {
		if (name.endsWith(".profraw")) { raws.push(dir + "/" + name); }
	}
	if (raws.length == 0) { return fail("the instrumented compiler wrote no profile under " + dir + "; was it built with -fprofile-instr-generate?"); }
	const merged = run([...llvmTool("llvm-profdata"), "merge", "-sparse", ...raws, "-o", dir + "/batch.profdata"], dir);
	if (!merged.ok) { return fail(merged.error); }
	const report = run([...llvmTool("llvm-cov"), "report", instrumented, "-instr-profile=" + dir + "/batch.profdata"], dir);
	if (!report.ok) { return fail(report.error); }
	const id = identify(root, instrumented);
	const text = "smith cov — seeds " + String(first) + ".." + String(first + ((count - 1) as uint64)) + ", " + vector + "\n" +
		"  instrumented " + instrumented + " (" + id.mscHash + "; source " + source.value.trim() + ")\n" +
		"  generator " + id.generator + "\n" +
		"  " + String(count) + " programs · " + String(emitted) + " emitted C\n" +
		formatRows(parseReport(report.value), sources.value);
	writeFile(dir + "/report.txt", text);
	console.log(text + "→ " + dir + "/report.txt");
	return 0;
}

test "a coverage table row keeps its region, function and branch counts" {
	const table = "Filename   Regions    Missed Regions     Cover   Functions  Missed Functions  Executed       Lines      Missed Lines     Cover    Branches   Missed Branches     Cover\n" +
		"-----\n" +
		"/o/.cache/rc_d_transform_d_lowering_d_lambdaLifting_x_ms.f1_40.ad_77.c     8    2    75.00%    2    0   100.00%    2    0   100.00%    4    2    50.00%\n" +
		"/o/.cache/runtime_d_drc_x_c.64_71.c     3    3    0.00%    1    1   0.00%    1    1   0.00%    0    0    -\n" +
		"TOTAL     11    5    54.55%    3    1   66.67%    3    1   66.67%    4    2    50.00%\n";
	const rows = parseReport(table);
	assert rows.length == 2;
	assert rows[0].regions == 8 && rows[0].missedRegions == 2 && rows[0].functions == 2 && rows[0].branches == 4 && rows[0].missedBranches == 2;
	assert rows[1].branches == 0;
}

test "a cache file maps back to the one compiler module whose path ends in its stem" {
	const sources = ["src/transform/lowering/lambdaLifting.ms", "src/transform/lowering/lambdaLiftingScope.ms", "src/utils/string.ms"];
	assert cacheStem("/o/.cache/rc_d_transform_d_lowering_d_lambdaLifting_x_ms.f1_40.ad_77.c") == "rc_d_transform_d_lowering_d_lambdaLifting_x_ms";
	assert moduleOf("rc_d_transform_d_lowering_d_lambdaLifting_x_ms", sources) == "src/transform/lowering/lambdaLifting.ms";
	assert moduleOf("transform_d_lowering_d_lambdaLiftingScope_x_ms", sources) == "src/transform/lowering/lambdaLiftingScope.ms";
	assert moduleOf("x_wt_d_wt-smith_d_src_d_utils_d_string_x_ms", sources) == "src/utils/string.ms";
	assert moduleOf("_src_d_utils_d_string_x_ms", sources) == "src/utils/string.ms";
	assert moduleOf("d_src_d_utils_d_string_x_ms", sources) == "src/utils/string.ms";
	assert moduleOf("x_wt_d_wt-smith_d_std_d_utils_d_string_x_ms", sources) == "";
	assert moduleOf("runtime_d_drc_x_c", sources) == "";
	assert moduleOf("g_x_ms", ["src/a/g.ms", "src/b/g.ms"]) == "";
}

test "the report lists compiler modules in path order with a total" {
	const rows = parseReport("/c/b_x_ms.1.c  4 1 75.00% 1 0 100.00% 1 0 100.00% 2 1 50.00%\n/c/a_x_ms.1.c  2 2 0.00% 1 1 0.00% 1 1 0.00% 0 0 -\n");
	const text = formatRows(rows, ["src/a.ms", "src/b.ms"]);
	assert text == "src/a.ms  regions 0/2  branches 0/0  functions 0/1\nsrc/b.ms  regions 3/4  branches 1/2  functions 1/1\npipeline total  regions 3/6  branches 1/2\n";
}
