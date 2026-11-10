// Incremental-compilation oracle: msc run --target=raiser src/test/ic/run.ms, from the recompiler root.
// Each case in cases/ is a sequence of edits; every step's warm build must emit the same C as a cold build
// of the same sources, and its counts must match what the step declares. Format: cases/README.md.
// Env: MSC=<path to msc> (default ./msc, else installed msc), IC_ONLY=<case,names> (stdUnit names the std unit check).
import { execFileResult, ExecFileResult, exit, env, cwd } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, remove, removeAll } from "std/fs";
import { parseJson } from "std/serialize/json/parser";
import { at, length, getDynamicField } from "std/serialize/json/accessors";
import { asString, asInt32 } from "std/serialize/json/types";

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
	verifyReasons: string[] = [];
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
	verify: boolean;
}

function parseCase(path: string): IcCase {
	const steps: IcStep[] = [];
	let xfail = "";
	let verify = false;
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
		} else if (line == "#!VERIFY") {
			verify = true;
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
	return { steps, xfail, verify };
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

function firstLine(s: string): string {
	const at = s.indexOf("\n");
	return at < 0 ? s : s.slice(0, at);
}

function isDigits(s: string): boolean {
	if (s == "") return false;
	for (let i: int32 = 0; i < s.byteLength; i += 1) {
		if (s.byteAt(i) < "0".code || s.byteAt(i) > "9".code) return false;
	}
	return true;
}

function diagnosticKey(severity: string, file: string, line: string, col: string, message: string): string {
	return `${severity} ${file}:${line}:${col} ${firstLine(message)}`;
}

function isDiagnosticHeader(line: string): boolean {
	return line.startsWith("error: ") || line.startsWith("warning: ") || line.startsWith("graph error: ");
}

// A build's diagnostics read back from its rendered stderr, so this oracle shares no code with the
// compiler's own recording of them.
function renderedDiagnostics(text: string): string[] {
	const keys: string[] = [];
	const lines = text.split("\n");
	for (let i = 0; i < lines.length; i += 1) {
		const line = lines[i];
		if (!isDiagnosticHeader(line)) continue;
		const colon = line.startsWith("graph error: ") ? -1 : line.indexOf(": ");
		const severity = line.startsWith("warning: ") ? "warning" : "error";
		const message = colon < 0 ? line : line.slice(colon + 2, line.length);
		let where = "";
		for (let j = i + 1; j < lines.length && lines[j] != "" && !isDiagnosticHeader(lines[j]); j += 1) {
			if (lines[j].startsWith("  --> ")) {
				where = lines[j].slice(6, lines[j].length);
				break;
			}
		}
		const parts = where.split(":");
		let lineNo = "0";
		let col = "0";
		if (parts.length >= 3 && isDigits(parts[parts.length - 1]) && isDigits(parts[parts.length - 2])) {
			col = parts.pop()!;
			lineNo = parts.pop()!;
		} else if (parts.length >= 2 && isDigits(parts[parts.length - 1])) {
			lineNo = parts.pop()!;
		}
		keys.push(diagnosticKey(severity, parts.join(":"), lineNo, col, message));
	}
	return keys;
}

// Each warm build's diagnostics, indexed by build number, from its build.done or build.failed event.
// The verify mode's own report of a difference is left out: it is the verdict under test.
function diagnosticsPerBuild(eventsPath: string): HashMap<int32, string[]> {
	const builds = new HashMap<int32, string[]>();
	for (const line of read(eventsPath).split("\n")) {
		if (!line.contains("\"event\":\"build.done\"") && !line.contains("\"event\":\"build.failed\"")) continue;
		const parsed = parseJson(line);
		if (!parsed.ok) {
			console.log(`FAIL icRunner: ${eventsPath}: an event is not JSON: ${line}`);
			exit(1);
		}
		const list = getDynamicField(parsed.value, "diagnostics");
		const keys: string[] = [];
		for (let i = 0; i < length(list); i += 1) {
			const d = at(list, i);
			const message = asString(getDynamicField(d, "message"));
			if (message.startsWith("internal: incremental verify")) continue;
			keys.push(diagnosticKey(asString(getDynamicField(d, "severity")), asString(getDynamicField(d, "file")), `${asInt32(getDynamicField(d, "line"))}`, `${asInt32(getDynamicField(d, "col"))}`, message));
		}
		builds.set(asInt32(getDynamicField(parsed.value, "build")), keys);
	}
	return builds;
}

function materialize(work: string, state: HashMap<string, string>, everWritten: HashSet<string>): void {
	for (const f of everWritten) {
		if (!state.has(f) && exists(`${work}/${f}`)) remove(`${work}/${f}`);
	}
	for (const [f, text] of state) put(`${work}/${f}`, text);
}

function verifyVerdict(log: string, build: int32): string {
	const head = `watch: verify build ${build}`;
	for (const line of log.split("\n")) {
		if (line.startsWith(`${head}:`)) return "equal";
		if (line.startsWith(`${head} differs:`)) return line.slice(head.length + 1, line.length);
	}
	return "";
}

function emittedDiffers(warmDir: string, coldDir: string): boolean {
	const warmFiles = cFilesIn(warmDir);
	const coldFiles = cFilesIn(coldDir);
	if (warmFiles.join(",") != coldFiles.join(",")) return true;
	for (const f of coldFiles) {
		if (read(`${warmDir}/${f}`) != read(`${coldDir}/${f}`)) return true;
	}
	return false;
}

function runCase(name: string, steps: IcStep[], verify: boolean): CaseFailure {
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
			return fail;
		}
		replay = replay + pairs.join(" ") + "\n";
	}
	put(`${dir}/replay.txt`, replay);

	const state = new HashMap<string, string>();
	for (const [f, text] of steps[0].writes) state.set(f, text);
	materialize(work, state, everWritten);
	env.set("MSC_CACHE_DIR", `${dir}/warmCache`);
	if (verify) env.set("MSC_IC_VERIFY", "1");
	const watched = execFileResult(MSC, ["build", "main.ms", "--hcr", `--watch-replay=${dir}/replay.txt`, "--emit=c", `--events=${dir}/events.jsonl`], work);
	env.delete("MSC_IC_VERIFY");
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
		return fail;
	}

	const debug = `${work}/out/debug`;
	const warmDiagnostics = diagnosticsPerBuild(`${dir}/events.jsonl`);
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

		const coldKeys = renderedDiagnostics(both(cold));
		const warmKeys = warmDiagnostics.has(k) ? warmDiagnostics.get(k)! : [] as string[];
		const diagnosticsDiffer = warmKeys.join("\n") != coldKeys.join("\n");
		if (diagnosticsDiffer && (warm.label != "failed" || step.attrs.has("fails"))) {
			fail.reasons.push(`${where}: diagnostics differ from a cold build:\nwarm:\n${warmKeys.join("\n")}\ncold:\n${coldKeys.join("\n")}`);
		}
		if (verify && step.attrs.has("fails")) {
			const said = verifyVerdict(warmLogs[k], k);
			if (said == "") fail.verifyReasons.push(`${where}: the warm session printed no verify result for the failed build ${k}`);
			if (said == "equal" && diagnosticsDiffer) fail.verifyReasons.push(`${where}: verify passed a failed build whose diagnostics differ from a cold build`);
			if (said.startsWith("differs") && !diagnosticsDiffer) fail.verifyReasons.push(`${where}: verify reported a difference a cold build does not show: ${said}`);
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
		if (verify) {
			const said = verifyVerdict(warmLogs[k], k);
			const differs = emittedDiffers(`${debug}/watch${k}`, debug) || diagnosticsDiffer;
			if (said == "" && warm.label != "failed") fail.verifyReasons.push(`${where}: the warm session printed no verify result for build ${k}`);
			if (said == "equal" && differs) fail.verifyReasons.push(`${where}: verify passed a build whose C differs from a cold build`);
			if (said.startsWith("differs") && !differs) fail.verifyReasons.push(`${where}: verify reported a difference a cold build does not show: ${said}`);
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
	return fail;
}

const STD_UNIT_CHECK = "stdUnit";
const STD_UNIT_ENV = ["MSC_NO_GLOBAL_CACHE", "MSC_GLOBAL_CACHE_DIR", "MSC_CACHE_DIR", "MSC_NO_STD_UNIT", "MSC_IC_VERIFY"];
const FOREIGN_UNIT = "[miss: a foreign or mismatched unit]x1";

const UNIT_PROGRAM_A = [
	"class Counter {",
	"\tcount: int32 = 0;",
	"\tbump(by: int32): int32 {",
	"\t\tthis.count += by;",
	"\t\treturn this.count;",
	"\t}",
	"}",
	"const scores = new Map<string, int32>();",
	"scores.set(\"a\", 1);",
	"const doubled = [1, 2, 3].map((n: int32): int32 => n * 2);",
	"const counter = new Counter();",
	"console.log(`${doubled.join(\",\")} ${scores.get(\"a\") ?? 0} ${counter.bump(2)}`);",
	"",
].join("\n");

const UNIT_PROGRAM_B = [
	"class Greeter {",
	"\tname: string;",
	"\tconstructor(name: string) {",
	"\t\tthis.name = name;",
	"\t}",
	"\tgreet(): string {",
	"\t\treturn `hi ${this.name}`;",
	"\t}",
	"}",
	"const ages = new Map<string, int32>();",
	"ages.set(\"b\", 2);",
	"const names = [\"x\", \"y\"].map((s: string): string => s.toUpperCase());",
	"console.log(`${new Greeter(names[0]).greet()} ${ages.size}`);",
	"",
].join("\n");

function restoreEnv(name: string, previous: string): void {
	if (previous == "") env.delete(name);
	else env.set(name, previous);
}

function lineWith(text: string, marker: string): string {
	for (const line of text.split("\n")) {
		if (line.contains(marker)) return line.trim();
	}
	return "";
}

function unitEvidence(r: ExecFileResult): string {
	const lines: string[] = [`exit ${r.exitCode}`];
	for (const line of both(r).split("\n")) {
		const t = line.trim();
		if (t.startsWith("stdUnit: ") || t.startsWith("verify: ") || t.contains("error") || t.contains("internal")) lines.push(t);
	}
	return lines.join("\n");
}

function stdUnitFiles(cache: string): string[] {
	const found: string[] = [];
	const base = `${cache}/stdunit`;
	if (!exists(base)) return found;
	for (const e of readDir(base)) {
		if (!e.endsWith("/")) continue;
		const dir = `${base}/${e.slice(0, e.length - 1)}`;
		for (const f of readDir(dir)) {
			if (f.endsWith(".su")) found.push(`${dir}/${f}`);
		}
	}
	return found;
}

function unitBuild(work: string, localCache: string, unit: boolean, verify: boolean): ExecFileResult {
	env.set("MSC_CACHE_DIR", localCache);
	if (unit) env.delete("MSC_NO_STD_UNIT");
	else env.set("MSC_NO_STD_UNIT", "1");
	if (verify) env.set("MSC_IC_VERIFY", "1");
	else env.delete("MSC_IC_VERIFY");
	return execFileResult(MSC, ["build", "main.ms", "--force", "--emit=c", "--time"], work);
}

function checkUnitStep(step: string, r: ExecFileResult, state: string, note: string, reasons: string[]): string {
	const unit = lineWith(both(r), "stdUnit: ");
	const verified = lineWith(both(r), "verify: ");
	const problems: string[] = [];
	if (!succeeded(r)) problems.push("the build failed");
	if (!verified.contains(" C units and ") || !verified.endsWith(" diagnostics equal a cold build")) problems.push("no 'verify: N C units and M diagnostics equal a cold build' line");
	if (!unit.contains(`state=${state} `)) problems.push(`the unit state is not ${state}`);
	if (note != "" && !unit.contains(note)) problems.push(`the unit notes lack '${note}'`);
	if (problems.length > 0) reasons.push(`${step}: ${problems.join("; ")}:\n${unitEvidence(r)}`);
	return unit;
}

function comptimeRead(exported: string, name: string, file: string): string {
	return `import { readFile } from "std/fs";\n\n${exported}const ${name}: string = @comptime {\n\tconst r = readFile("${file}");\n\tif (!r.ok) return "missing";\n\treturn r.value;\n};\n`;
}

function runStdUnitSteps(dir: string, cache: string, project: string, reasons: string[]): void {
	const a = `${project}/a`;
	const b = `${project}/b`;
	checkUnitStep("step 1 (first build, fresh global cache)", unitBuild(a, `${dir}/localCache1`, true, true), "written", "[miss: no unit]x1", reasons);
	const units = stdUnitFiles(cache);
	if (units.length != 1) {
		reasons.push(`step 1 (first build, fresh global cache): ${units.length} units under ${cache}/stdunit, expected 1: [${units.join(", ")}]`);
		return;
	}
	const path = units[0];

	const hit = checkUnitStep("step 2 (second program, same project)", unitBuild(b, `${dir}/localCache2`, true, true), "hit", "", reasons);
	if (hit.contains(" [")) reasons.push(`step 2 (second program, same project): a hit carries notes:\n${hit}`);

	const loose = `${dir}/loose`;
	put(`${loose}/one/main.ms`, UNIT_PROGRAM_A);
	put(`${loose}/two/main.ms`, UNIT_PROGRAM_B);
	checkUnitStep("step 2a (a program with no build.ms)", unitBuild(`${loose}/one`, `${dir}/localCache2a`, true, true), "written", "[miss: no unit]x1", reasons);
	checkUnitStep("step 2a (a program with no build.ms in another directory)", unitBuild(`${loose}/two`, `${dir}/localCache2a2`, true, true), "hit", "", reasons);
	if (stdUnitFiles(cache).length != 2) reasons.push(`step 2a: ${stdUnitFiles(cache).length} units under ${cache}/stdunit, expected one for the build.ms project and one shared by the two directories without one`);

	const c = `${project}/c`;
	put(`${c}/first.txt`, "a");
	put(`${c}/second.txt`, "b");
	put(`${c}/lib.ms`, comptimeRead("export ", "SECOND", "second.txt"));
	put(`${c}/main.ms`, `${comptimeRead("", "FIRST", "first.txt")}import { SECOND } from "./lib";\n\nconsole.log(FIRST + SECOND);\n`);
	checkUnitStep("step 2b (a compile-time file read in two modules after a hit)", unitBuild(c, `${dir}/localCache2b`, true, true), "hit", "", reasons);

	const whole = read(path);
	const headerEnd = whole.indexOf("\n", whole.indexOf("\n") + 1);
	const torn = whole.slice(0, whole.length / 2);
	if (headerEnd < 0 || torn.length <= headerEnd) {
		reasons.push(`step 3 (torn unit): ${path} holds ${whole.length} characters, too few to tear past its header`);
		return;
	}
	put(path, torn);
	const tornLine = checkUnitStep("step 3 (torn unit)", unitBuild(a, `${dir}/localCache3`, true, true), "written", "[miss: ", reasons);
	if (tornLine.contains("[miss: no unit]") || tornLine.contains(FOREIGN_UNIT)) reasons.push(`step 3 (torn unit): the miss names no decoding problem:\n${tornLine}`);
	if (read(path).length <= torn.length) reasons.push(`step 3 (torn unit): ${path} was not rewritten (${read(path).length} characters, torn ${torn.length})`);

	const rewritten = read(path);
	const first = rewritten.indexOf("\n");
	const second = rewritten.indexOf("\n", first + 1);
	if (first < 0 || second < 0 || rewritten.slice(first + 1, first + 3) != "K\t") {
		reasons.push(`step 4 (foreign key): ${path} has no 'K' key line after its magic`);
		return;
	}
	put(path, rewritten.slice(0, first + 1) + "K\tforeign" + rewritten.slice(second, rewritten.length));
	checkUnitStep("step 4 (foreign key)", unitBuild(b, `${dir}/localCache4`, true, true), "written", FOREIGN_UNIT, reasons);

	const inert = unitBuild(a, `${dir}/localCache5`, false, false);
	if (!succeeded(inert) || !both(inert).contains("preludePack: ")) reasons.push(`step 5 (MSC_NO_STD_UNIT=1): the build failed or printed no --time check lines:\n${unitEvidence(inert)}`);
	if (lineWith(both(inert), "stdUnit: ") != "") reasons.push(`step 5 (MSC_NO_STD_UNIT=1): the unit is not inert:\n${lineWith(both(inert), "stdUnit: ")}`);
}

function runStdUnitCheck(): string[] {
	const reasons: string[] = [];
	const dir = `${TMP}/${STD_UNIT_CHECK}`;
	removeAll(dir);
	const cache = `${dir}/globalCache`;
	const project = `${dir}/project`;
	put(`${project}/build.ms`, "const config = {};\nexport default config;\n");
	put(`${project}/a/main.ms`, UNIT_PROGRAM_A);
	put(`${project}/b/main.ms`, UNIT_PROGRAM_B);
	const saved: string[] = [];
	for (const name of STD_UNIT_ENV) saved.push(env.get(name));
	env.delete("MSC_NO_GLOBAL_CACHE");
	env.set("MSC_GLOBAL_CACHE_DIR", cache);
	runStdUnitSteps(dir, cache, project, reasons);
	for (let i = 0; i < STD_UNIT_ENV.length; i += 1) restoreEnv(STD_UNIT_ENV[i], saved[i]);
	return reasons;
}

const only = env.get("IC_ONLY") == "" ? [] as string[] : env.get("IC_ONLY").split(",");
const names: string[] = [];
for (const e of readDir(CASES)) {
	if (!e.endsWith(".txt")) continue;
	if (only.length > 0 && !only.includes(e.replace(".txt", ""))) continue;
	names.push(e);
}
names.sort();
const unitSelected = only.length == 0 || only.includes(STD_UNIT_CHECK);
const checks = names.length + (unitSelected ? 1 : 0);
if (only.length > 0 && checks != only.length) {
	console.log(`FAIL icRunner: IC_ONLY names ${only.length} case(s), ${checks} found`);
	exit(1);
}
let failed = 0;
let expected = 0;
for (const name of names) {
	const c = parseCase(`${CASES}/${name}`);
	const result = runCase(name, c.steps, c.verify);
	const reasons = result.reasons;
	const tag = name.replace(".txt", "");
	if (result.verifyReasons.length > 0) {
		failed += 1;
		for (const r of result.verifyReasons) console.log(`FAIL ${tag}: verify: ${r}`);
	} else if (c.xfail != "" && reasons.length > 0) {
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
if (unitSelected) {
	const reasons = runStdUnitCheck();
	if (reasons.length == 0) {
		console.log(`ok   ${STD_UNIT_CHECK}`);
	} else {
		failed += 1;
		for (const r of reasons) console.log(`FAIL ${STD_UNIT_CHECK}: ${r}`);
	}
}
console.log(`ic: ${checks - failed - expected} passed, ${expected} expected red, ${failed} failed`);
if (failed > 0) exit(1);
