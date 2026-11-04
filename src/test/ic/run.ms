// Incremental-compilation oracle: msc run --target=raiser src/test/ic/run.ms, from the recompiler root.
// Each case in cases/ is a sequence of edits; every step's warm build must emit the same C as a cold build
// of the same sources, and its counts must match what the step declares. Format: cases/README.md.
// Env: MSC=<path to msc> (default ./msc, else installed msc), IC_ONLY=<case,names>.
import { execFileResult, ExecFileResult, exit, env, cwd } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, remove, removeAll } from "std/fs";

function slashes(p: string): string {
	return p.replaceAll("\\", "/");
}

const ROOT = slashes(cwd());

function resolveMsc(): string {
	const explicit = slashes(env.get("MSC"));
	if (explicit != "") {
		if (explicit.indexOf("/") < 0) return explicit;
		return explicit.startsWith("/") || explicit.indexOf(":") >= 0 ? explicit : `${ROOT}/${explicit}`;
	}
	if (exists("./msc") || exists("./msc.exe")) return `${ROOT}/msc`;
	return "msc";
}

const MSC = resolveMsc();
env.set("NO_COLOR", "1");
env.set("MSC_NO_GLOBAL_CACHE", "1");
const CASES = `${ROOT}/src/test/ic/cases`;
const TMP = `${ROOT}/out/ic`;

interface IcStep {
	writes: HashMap<string, string>;
	attrs: HashMap<string, string>;
	line: int32;
}

class CaseFailure {
	reasons: string[] = [];
}

function both(r: ExecFileResult): string {
	return r.output + r.errorOutput;
}

function succeeded(r: ExecFileResult): boolean {
	return r.started && r.pipeOk && r.exitCode == 0 && r.signal == 0;
}

function read(path: string): string {
	const r = readFile(path);
	return r.ok ? r.value : "";
}

function put(path: string, content: string): void {
	const slash = path.lastIndexOf("/");
	if (slash > 0) ensureDir(path.slice(0, slash));
	if (!writeFile(path, content).ok) {
		console.log(`FAIL icRunner: cannot write ${path}`);
		exit(1);
	}
}

function parseAttrs(text: string): HashMap<string, string> {
	const attrs = new HashMap<string, string>();
	for (const raw of text.split(";")) {
		const item = raw.trim();
		if (item == "") continue;
		const colon = item.indexOf(":");
		if (colon < 0) attrs.set(item, "");
		else attrs.set(item.slice(0, colon).trim(), item.slice(colon + 1, item.length).trim());
	}
	return attrs;
}

const KNOWN_ATTRS = ["expect", "noop", "body-edit", "iface-edit", "modules", "rechecked", "lowered", "rebuilt", "fails"];

interface IcCase {
	steps: IcStep[];
	xfail: string;
}

function parseCase(path: string): IcCase {
	const steps: IcStep[] = [];
	let xfail = "";
	let writes = new HashMap<string, string>();
	let file = "";
	let body: string[] = [];
	let lineNo = 0;
	const flush = (): void => {
		if (file != "") writes.set(file, body.join("\n") + "\n");
		file = "";
		body = [];
	};
	for (const raw of read(path).split("\n")) {
		lineNo += 1;
		const line = raw.endsWith("\r") ? raw.slice(0, raw.length - 1) : raw;
		if (line.startsWith("#!FILE ")) {
			flush();
			file = line.slice(7, line.length).trim();
		} else if (line.startsWith("#!STEP")) {
			flush();
			const attrs = parseAttrs(line.slice(6, line.length));
			for (const key of attrs.keys()) {
				if (!KNOWN_ATTRS.includes(key)) {
					console.log(`FAIL icRunner: ${path}:${lineNo}: unknown step attribute '${key}'`);
					exit(1);
				}
			}
			steps.push({ writes, attrs, line: lineNo });
			writes = new HashMap<string, string>();
		} else if (line.startsWith("#!XFAIL ")) {
			xfail = line.slice(8, line.length).trim();
		} else if (line.startsWith("#!")) {
			console.log(`FAIL icRunner: ${path}:${lineNo}: unknown directive '${line}'`);
			exit(1);
		} else if (file != "") {
			body.push(line);
		}
	}
	if (file != "" || writes.size > 0) {
		console.log(`FAIL icRunner: ${path}: files after the last #!STEP belong to no step`);
		exit(1);
	}
	if (steps.length == 0 || !steps[0].writes.has("main.ms")) {
		console.log(`FAIL icRunner: ${path}: the first step must write main.ms, the build root`);
		exit(1);
	}
	return { steps, xfail };
}

function cFilesIn(dir: string): string[] {
	const names: string[] = [];
	if (!exists(dir)) return names;
	for (const e of readDir(dir)) {
		if (e.endsWith(".c")) names.push(e);
	}
	names.sort();
	return names;
}

// "watch: build <n> <label> in <ms> ms (checked a/b, lowered c)"
interface WarmStatus {
	label: string;
	checked: int64;
	lowered: int64;
	text: string;
}

function parseStatus(line: string): WarmStatus {
	const words = line.split(" ");
	const at = line.indexOf("(checked ");
	const slash = line.indexOf("/", at);
	const lowAt = line.indexOf("lowered ", at);
	const close = line.indexOf(")", lowAt);
	return {
		label: words.length > 3 ? words[3] : "",
		checked: at < 0 ? -1 : parseInt(line.slice(at + 9, slash)),
		lowered: lowAt < 0 ? -1 : parseInt(line.slice(lowAt + 8, close)),
		text: line,
	};
}

// The project modules each successful build rechecked, in build order, read from its build.done events.
function recheckedPerBuild(eventsPath: string, work: string): string[][] {
	const builds: string[][] = [];
	for (const line of read(eventsPath).split("\n")) {
		if (!line.contains("\"event\":\"build.done\"")) continue;
		const at = line.indexOf("\"rechecked\":[");
		const names: string[] = [];
		if (at >= 0) {
			const list = line.slice(at + 13, line.indexOf("]", at));
			for (const item of list.split(",")) {
				const path = item.replaceAll("\"", "");
				if (path.startsWith(`${work}/`)) names.push(path.slice(work.length + 1, path.length));
			}
		}
		builds.push(names);
	}
	return builds;
}

function materialize(work: string, state: HashMap<string, string>, everWritten: HashSet<string>): void {
	for (const f of everWritten) {
		if (!state.has(f) && exists(`${work}/${f}`)) remove(`${work}/${f}`);
	}
	for (const [f, text] of state) put(`${work}/${f}`, text);
}

function runCase(name: string, steps: IcStep[]): string[] {
	const fail = new CaseFailure();
	const dir = `${TMP}/${name.replace(".txt", "")}`;
	removeAll(dir);
	const work = `${dir}/work`;
	ensureDir(work);

	const everWritten = new HashSet<string>();
	for (const s of steps) for (const f of s.writes.keys()) everWritten.add(f);
	let replay = "";
	for (let k = 1; k < steps.length; k += 1) {
		const pairs: string[] = [];
		for (const [f, text] of steps[k].writes) {
			put(`${dir}/steps/${k}/${f}`, text);
			pairs.push(`${dir}/steps/${k}/${f} ${f}`);
		}
		if (pairs.length == 0) {
			fail.reasons.push(`step ${k + 1} (line ${steps[k].line}) writes no file`);
			return fail.reasons;
		}
		replay = replay + pairs.join(" ") + "\n";
	}
	put(`${dir}/replay.txt`, replay);

	const state = new HashMap<string, string>();
	for (const [f, text] of steps[0].writes) state.set(f, text);
	materialize(work, state, everWritten);
	env.set("MSC_CACHE_DIR", `${dir}/warmCache`);
	const watched = execFileResult(MSC, ["build", "main.ms", "--hcr", `--watch-replay=${dir}/replay.txt`, "--emit=c", `--events=${dir}/events.jsonl`], work);
	const statuses: WarmStatus[] = [];
	const warmLogs: string[] = [];
	let log = "";
	for (const line of both(watched).split("\n")) {
		if (line.startsWith("watch: build ")) {
			statuses.push(parseStatus(line.trim()));
			warmLogs.push(log);
			log = "";
		} else {
			log += line + "\n";
		}
	}
	if (statuses.length != steps.length) {
		fail.reasons.push(`the warm session reported ${statuses.length} builds for ${steps.length} steps:\n${both(watched)}`);
		return fail.reasons;
	}

	const debug = `${work}/out/debug`;
	for (let k = 0; k < steps.length; k += 1) {
		const step = steps[k];
		const where = `step ${k + 1} (line ${step.line})`;
		if (k > 0) for (const [f, text] of step.writes) state.set(f, text);
		materialize(work, state, everWritten);
		for (const f of cFilesIn(debug)) remove(`${debug}/${f}`);
		env.set("MSC_CACHE_DIR", `${dir}/coldCache${k}`);
		const cold = execFileResult(MSC, ["build", "main.ms", "--hcr", "--emit=c"], work);
		const warm = statuses[k];
		if (warm.label != "failed") {
			const names = recheckedPerBuild(`${dir}/events.jsonl`, work);
			const done = statuses.slice(0, k).filter((s: WarmStatus): boolean => s.label != "failed").length;
			if (done < names.length) warm.text = `${warm.text} rechecked [${names[done].join(" ")}]`;
		}

		if (step.attrs.has("fails")) {
			const want = step.attrs.get("fails")!;
			if (succeeded(cold) || !both(cold).contains(want)) fail.reasons.push(`${where}: the cold build should fail with '${want}':\n${both(cold)}`);
			if (warm.label != "failed") fail.reasons.push(`${where}: the warm build should fail: ${warm.text}`);
			continue;
		}
		if (!succeeded(cold)) {
			fail.reasons.push(`${where}: the cold build failed:\n${both(cold)}`);
			continue;
		}
		if (warm.label == "failed") {
			fail.reasons.push(`${where}: the warm build failed: ${warm.text}\n${warmLogs[k]}${watched.errorOutput}`);
			continue;
		}
		const warmFiles = cFilesIn(`${debug}/watch${k}`);
		const coldFiles = cFilesIn(debug);
		if (coldFiles.length == 0) fail.reasons.push(`${where}: the cold build wrote no C to ${debug}, so nothing was compared`);
		if (warmFiles.join(",") != coldFiles.join(",")) {
			fail.reasons.push(`${where}: warm emitted [${warmFiles.join(", ")}], cold [${coldFiles.join(", ")}]`);
		}
		for (const f of coldFiles) {
			if (warmFiles.includes(f) && read(`${debug}/watch${k}/${f}`) != read(`${debug}/${f}`)) {
				fail.reasons.push(`${where}: ${f} differs from a cold build (diff ${debug}/watch${k}/${f} ${debug}/${f})`);
			}
		}

		if (k > 0) {
			if (warm.label == "rebuilt" && !step.attrs.has("rebuilt")) fail.reasons.push(`${where}: the warm session fell back to a full rebuild: ${warm.text}`);
			if (warm.label != "rebuilt" && step.attrs.has("rebuilt")) fail.reasons.push(`${where}: declared rebuilt, stayed warm: ${warm.text}`);
			const edited = step.writes.size;
			if (step.attrs.has("noop") && (warm.checked != 0 || warm.lowered != 0)) fail.reasons.push(`${where}: a no-op edit rechecked or relowered: ${warm.text}`);
			if (step.attrs.has("body-edit") && warm.checked != edited) fail.reasons.push(`${where}: a body edit of ${edited} module(s) rechecked ${warm.checked}: ${warm.text}`);
			if (step.attrs.has("iface-edit") && warm.checked < 2) fail.reasons.push(`${where}: an interface edit reached no importer: ${warm.text}`);
			if (step.attrs.has("modules") && `${warm.checked}` != step.attrs.get("modules")!) fail.reasons.push(`${where}: rechecked ${warm.checked}, declared ${step.attrs.get("modules")!}: ${warm.text}`);
			if (step.attrs.has("rechecked") && !warm.text.endsWith(`rechecked [${step.attrs.get("rechecked")!}]`)) fail.reasons.push(`${where}: declared rechecked [${step.attrs.get("rechecked")!}]: ${warm.text}`);
			if (step.attrs.has("lowered") && `${warm.lowered}` != step.attrs.get("lowered")!) fail.reasons.push(`${where}: relowered ${warm.lowered}, declared ${step.attrs.get("lowered")!}: ${warm.text}`);
		}

		if (step.attrs.has("expect")) {
			const want = step.attrs.get("expect")!.replaceAll("\\n", "\n").trim();
			env.set("MSC_CACHE_DIR", `${dir}/runCache${k}`);
			const ran = execFileResult(MSC, ["run", "main.ms"], work);
			if (!succeeded(ran) || ran.output.trim() != want) fail.reasons.push(`${where}: expected '${want}', the program printed:\n${both(ran)}`);
		}
	}
	return fail.reasons;
}

const only = env.get("IC_ONLY") == "" ? [] as string[] : env.get("IC_ONLY").split(",");
const names: string[] = [];
for (const e of readDir(CASES)) {
	if (!e.endsWith(".txt")) continue;
	if (only.length > 0 && !only.includes(e.replace(".txt", ""))) continue;
	names.push(e);
}
names.sort();
if (only.length > 0 && names.length != only.length) {
	console.log(`FAIL icRunner: IC_ONLY names ${only.length} case(s), ${names.length} found`);
	exit(1);
}
let failed = 0;
let expected = 0;
for (const name of names) {
	const c = parseCase(`${CASES}/${name}`);
	const reasons = runCase(name, c.steps);
	const tag = name.replace(".txt", "");
	if (c.xfail != "" && reasons.length > 0) {
		expected += 1;
		console.log(`xfail ${tag}: ${c.xfail}`);
		for (const r of reasons) console.log(`      ${r.split("\n")[0]}`);
	} else if (c.xfail != "") {
		failed += 1;
		console.log(`FAIL ${tag}: green, drop its #!XFAIL (${c.xfail})`);
	} else if (reasons.length == 0) {
		console.log(`ok   ${tag}`);
	} else {
		failed += 1;
		for (const r of reasons) console.log(`FAIL ${tag}: ${r}`);
	}
}
console.log(`ic: ${names.length - failed - expected} passed, ${expected} expected red, ${failed} failed`);
if (failed > 0) exit(1);
