import { cwd, env, execFileResult, findOnPath, platform } from "std/process";
import { copyFile, ensureDir, exists, readFile, realpath, removeAll, writeFile } from "std/fs";
import { basename } from "std/fs/path";
import { djb2, fingerprint, hashToHex } from "std/hash";
import { Features, defaults, format, overlay, swarm } from "./features";
import { generate } from "./gen";

const GENERATOR_SOURCES: string[] = ["rng.ms", "features.ms", "gen.ms"];
const CELL_FILES: string[] = ["out.log", "done", "build.log", "err.log", "stdout.log"];
const FINDING_KINDS: string[] = ["wrong-code", "crash", "unrated", "timeout", "unjudged", "san"];
const REQUIRED_KEYS: string[] = ["seed", "features", "kind", "split", "generator", "msc", "msc-hash", "msc-version", "support", "runner", "mode"];
const MODE_PARITY = "parity";
const MODE_SAN = "san";

struct LaneResult {
	lane: string;
	pass: boolean;
	detail: string;
}

struct Verdict {
	kind: string;
	split: string;
	lanes: LaneResult[];
	lines: string;
}

struct Paths {
	root: string;
	sandbox: string;
	programs: string;
	cells: string;
	bundles: string;
	reruns: string;
}

export struct Identity {
	generator: string;
	msc: string;
	mscHash: string;
	mscVersion: string;
	support: string;
	runner: string;
}

struct Recorded {
	seed: uint64;
	features: Features;
	kind: string;
	split: string;
	generator: string;
	msc: string;
	mscHash: string;
	support: string;
	runner: string;
	mode: string;
	lanes: string[];
	laneLines: string[];
}

function slashes(p: string): string { return p.replaceAll("\\", "/"); }

function fail(msg: string): int32 {
	console.log("smith: " + msg);
	return 2;
}

function pathsUnder(root: string, work: string): Paths {
	const sandbox = work + "/sandbox";
	return {
		root: root,
		sandbox: sandbox,
		programs: sandbox + "/src/test/corpus/programs",
		cells: sandbox + "/out/corpus/cells",
		bundles: work + "/bundles",
		reruns: work + "/reruns",
	};
}

function paths(): Paths {
	const root = slashes(cwd());
	return pathsUnder(root, root + "/out/smith");
}

function contentHash(text: string): string {
	return hashToHex(djb2(text)) + "_" + hashToHex(fingerprint(text)) + ":" + String(text.byteLength);
}

function stripAnsi(text: string): string {
	let out = "";
	let i = 0;
	while (i < text.length) {
		if (text.charCodeAt(i) == 27) {
			while (i < text.length && text.charCodeAt(i) != 109) { i++; }
			i++;
			continue;
		}
		out += text.slice(i, i + 1);
		i++;
	}
	return out;
}

function git(dir: string, args: string[]): string {
	const r = execFileResult("git", ["-C", dir, ...args]);
	if (!r.started || r.exitCode != 0) { return ""; }
	return r.output.trim();
}

function generatorIdentity(root: string): string {
	let sources = "";
	for (const name of GENERATOR_SOURCES) {
		const r = readFile(root + "/tools/smith/" + name);
		sources += r.ok ? r.value : "<missing " + name + ">";
	}
	const head = git(root, ["rev-parse", "HEAD"]);
	const dirty = git(root, ["status", "--porcelain", "--", "tools/smith"]) != "";
	return (head == "" ? "no-git" : head) + (dirty ? " dirty " : " clean ") + contentHash(sources);
}

function runnerIdentity(root: string): string {
	const run = readFile(root + "/src/test/corpus/run.ms");
	const wintime = readFile(root + "/src/test/corpus/wintime.c");
	return contentHash((run.ok ? run.value : "<missing run.ms>") + "\n" + (wintime.ok ? wintime.value : "<missing wintime.c>"));
}

function supportIdentity(binary: string): string {
	const dir = binary.slice(0, binary.lastIndexOf("/"));
	const build = readFile(dir + "/../BUILD");
	if (build.ok) { return "BUILD " + build.value.trim().replaceAll("\n", "; "); }
	const trees = git(dir, ["rev-parse", "HEAD:src", "HEAD:std", "HEAD:runtime"]);
	if (trees == "") { return "unknown: no BUILD beside the binary and not a git checkout"; }
	const dirty = git(dir, ["status", "--porcelain", "--", "src", "std", "runtime"]) != "";
	return "git trees " + trees.replaceAll("\n", " ") + (dirty ? " with uncommitted src/std/runtime" : "");
}

export function subjectMsc(root: string): string {
	const explicit = env.get("MSC");
	if (explicit != "") { return slashes(realpath(explicit)); }
	const exe = platform == "windows" ? "/msc.exe" : "/msc";
	if (exists(root + exe)) { return root + exe; }
	const installed = findOnPath("msc");
	return installed == "" ? "" : slashes(realpath(installed));
}

export function identify(root: string, msc: string): Identity {
	const binary = readFile(msc);
	const version = execFileResult(msc, ["--version"]);
	return {
		generator: generatorIdentity(root),
		msc: msc,
		mscHash: binary.ok ? contentHash(binary.value) : "unreadable",
		mscVersion: version.started ? stripAnsi(version.output + version.errorOutput).trim() : "did not start",
		support: supportIdentity(msc),
		runner: runnerIdentity(root),
	};
}

export function programName(seed: uint64, f: Features): string {
	return "smith" + String(seed) + "-" + hashToHex(djb2(f.format())).slice(0, 8);
}

function prepareSandbox(p: Paths): string {
	removeAll(p.programs);
	removeAll(p.cells);
	removeAll(p.sandbox + "/runner.log");
	if (exists(p.cells) || exists(p.sandbox + "/runner.log")) {
		return "the sandbox kept cells or a runner log from an earlier run under " + p.sandbox + "; classification would read stale evidence";
	}
	ensureDir(p.programs);
	copyFile(p.root + "/src/test/corpus/wintime.c", p.sandbox + "/src/test/corpus/wintime.c");
	return "";
}

function runCorpus(p: Paths, msc: string, san: boolean): Result<string, string> {
	const harness = findOnPath("msc");
	if (harness == "") { return Result.err("no installed msc on PATH to run the corpus harness"); }
	env.set("MSC", msc);
	env.set("MSCORPUS_ONLY", "");
	env.set("MSCORPUS_FILTER", "");
	env.set("MSCORPUS_SAN", san ? "1" : "0");
	if (env.get("MSCORPUS_CELL_TIMEOUT_MS") == "") { env.set("MSCORPUS_CELL_TIMEOUT_MS", "60000"); }
	const r = execFileResult(harness, ["run", p.root + "/src/test/corpus/run.ms"], p.sandbox);
	const log = r.output + r.errorOutput;
	writeFile(p.sandbox + "/runner.log", log);
	if (!r.started) { return Result.err("the corpus harness did not start: " + harness); }
	if (!log.contains("Corpus tier — ")) {
		return Result.err("the corpus harness printed no header; its log is " + p.sandbox + "/runner.log");
	}
	if (log.contains("SAN BLOCKED")) {
		return Result.err("the SAN lane is blocked on this host; see " + p.sandbox + "/runner.log");
	}
	if (log.contains("SAN lane (") != san) {
		return Result.err("the corpus harness ran in the other mode than " + (san ? MODE_SAN : MODE_PARITY) + "; see " + p.sandbox + "/runner.log");
	}
	if (!log.contains("(msc=" + msc + ",")) {
		return Result.err("the corpus harness tested a different compiler than " + msc + "; see " + p.sandbox + "/runner.log");
	}
	return Result.ok(log);
}

function laneLine(line: string, name: string): LaneResult | null {
	let rest = "";
	let pass = false;
	if (line.startsWith("✓ ")) {
		rest = line.slice("✓ ".length, line.length);
		pass = true;
	} else if (line.startsWith("✗ FAIL ")) {
		rest = line.slice("✗ FAIL ".length, line.length);
	} else {
		return null;
	}
	if (!rest.startsWith(name + " [")) { return null; }
	const close = rest.indexOf("]");
	if (close < 0) { return null; }
	const lane = rest.slice(name.length + 2, close);
	const dash = rest.indexOf(" — ");
	const detail = dash < 0 ? "" : rest.slice(dash + " — ".length, rest.length);
	return { lane: lane, pass: pass, detail: detail };
}

const LANE_ORDER: string[] = ["c", "drc", "orc", "danger", "js", "esm", "raiser"];

function laneRank(lane: string): int32 {
	for (let i = 0; i < LANE_ORDER.length; i++) { if (LANE_ORDER[i] == lane) { return i; } }
	return LANE_ORDER.length;
}

function sortLanes(lanes: LaneResult[]): LaneResult[] {
	const out: LaneResult[] = [];
	for (let rank = 0; rank <= LANE_ORDER.length; rank++) {
		for (const r of lanes) { if (laneRank(r.lane) == rank) { out.push(r); } }
	}
	return out;
}

function outputSplit(cells: string, name: string, lanes: LaneResult[]): string {
	const outputs: string[] = [];
	const groups: string[] = [];
	for (const r of lanes) {
		const out = laneFile(cells + "/" + name + "." + r.lane, "out.log");
		let found = -1;
		for (let g = 0; g < outputs.length; g++) { if (outputs[g] == out) { found = g; } }
		if (found < 0) {
			outputs.push(out);
			groups.push(r.lane);
		} else {
			groups[found] = groups[found] + " " + r.lane;
		}
	}
	return groups.join(" | ");
}

function passSplit(lanes: LaneResult[]): string {
	let pass = "";
	let fail = "";
	for (const r of lanes) {
		if (r.pass) { pass += " " + r.lane; } else { fail += " " + r.lane; }
	}
	return "pass" + pass + " | fail" + fail;
}

function sanSymptom(detail: string): boolean {
	return detail.contains("AddressSanitizer") || detail.contains("DOUBLE-DESTROY") || detail.contains("[ledger ") || detail.contains("[no LEDGER output");
}

function classify(log: string, name: string, cells: string, san: boolean): Verdict {
	const found: LaneResult[] = [];
	let parity: LaneResult | null = null;
	let lines = "";
	for (const raw of log.split("\n")) {
		const line = raw.trim();
		const r = laneLine(line, name);
		if (r === null) { continue; }
		lines += line + "\n";
		if (r.lane == "parity") { parity = r; } else { found.push(r); }
	}
	const lanes = sortLanes(found);
	if (lanes.length == 0) { return { kind: "missing", split: "", lanes: lanes, lines: lines }; }
	let failed = 0;
	for (const r of lanes) {
		if (r.detail.contains("TIMEOUT")) { return { kind: "timeout", split: r.lane, lanes: lanes, lines: lines }; }
		if (!r.pass) { failed++; }
	}
	if (san) {
		for (const r of lanes) {
			if (!r.pass) { return { kind: sanSymptom(r.detail) ? "san" : "unrated", split: r.lane, lanes: lanes, lines: lines }; }
		}
		return { kind: "clean", split: "", lanes: lanes, lines: lines };
	}
	if (failed == lanes.length) { return { kind: "unrated", split: passSplit(lanes), lanes: lanes, lines: lines }; }
	if (failed > 0) { return { kind: "crash", split: passSplit(lanes), lanes: lanes, lines: lines }; }
	if (parity === null) { return { kind: "unjudged", split: "", lanes: lanes, lines: lines }; }
	if (parity.pass) { return { kind: "clean", split: "", lanes: lanes, lines: lines }; }
	return { kind: "wrong-code", split: outputSplit(cells, name, lanes), lanes: lanes, lines: lines };
}

function metaText(seed: uint64, f: Features, id: Identity, v: Verdict, san: boolean): string {
	let lanes = "";
	for (const r of v.lanes) { lanes += "lane: " + r.lane + " " + (r.pass ? "pass" : "fail") + " " + r.detail + "\n"; }
	return "seed: " + String(seed) + "\n" +
		"features: " + f.format() + "\n" +
		"kind: " + v.kind + "\n" +
		"split: " + v.split + "\n" +
		"generator: " + id.generator + "\n" +
		"msc: " + id.msc + "\n" +
		"msc-hash: " + id.mscHash + "\n" +
		"msc-version: " + id.mscVersion + "\n" +
		"support: " + id.support + "\n" +
		"runner: " + id.runner + "\n" +
		"mode: " + (san ? MODE_SAN : MODE_PARITY) + "\n" +
		lanes;
}

function bundleDir(parent: string, name: string, meta: string, program: string): string {
	return parent + "/" + name + "-" + hashToHex(djb2(meta + "\n" + program)).slice(0, 8);
}

function writeBundle(dir: string, p: Paths, name: string, program: string, meta: string, v: Verdict): void {
	ensureDir(dir + "/lanes");
	writeFile(dir + "/program.ms", program);
	writeFile(dir + "/meta.txt", meta);
	writeFile(dir + "/verdict.txt", v.lines);
	for (const r of v.lanes) {
		for (const file of CELL_FILES) {
			const from = p.cells + "/" + name + "." + r.lane + "/" + file;
			if (exists(from)) { copyFile(from, dir + "/lanes/" + r.lane + "." + file); }
		}
	}
}

function isFinding(kind: string): boolean { return kind != "clean"; }

export function runSeeds(first: uint64, count: int32, base: Features, swarmed: boolean, san: boolean): int32 {
	const p = paths();
	if (!exists(p.root + "/src/test/corpus/run.ms")) { return fail("run from the repo root: no src/test/corpus/run.ms under " + p.root); }
	const msc = subjectMsc(p.root);
	if (msc == "") { return fail("no compiler under test: set MSC, build ./msc, or install msc"); }
	const id = identify(p.root, msc);
	const stale = prepareSandbox(p);
	if (stale != "") { return fail(stale); }
	const names: string[] = [];
	const programs: string[] = [];
	const vectors: Features[] = [];
	for (let i = 0; i < count; i++) {
		const seed = first + (i as uint64);
		const f = swarmed ? base.swarm(seed) : base;
		vectors.push(f);
		const name = programName(seed, f);
		const program = generate(seed, f);
		writeFile(p.programs + "/" + name + ".ms", program);
		names.push(name);
		programs.push(program);
	}
	console.log("smith run — seeds " + String(first) + ".." + String(first + ((count - 1) as uint64)) + ", " + (san ? "SAN lane, " : "") + (swarmed ? "swarm over " : "") + base.format());
	console.log("  msc " + id.msc + " (" + id.mscVersion + ", " + id.mscHash + "; " + id.support + ")");
	console.log("  generator " + id.generator);
	const log = runCorpus(p, msc, san);
	if (!log.ok) { return fail(log.error); }
	let clean = 0;
	let findings = 0;
	let notBugs = 0;
	for (let i = 0; i < count; i++) {
		const seed = first + (i as uint64);
		const v = classify(log.value, names[i], p.cells, san);
		if (v.kind == "missing") { return fail("the corpus harness reported nothing for " + names[i] + "; see " + p.sandbox + "/runner.log"); }
		if (!isFinding(v.kind)) {
			clean++;
			continue;
		}
		const meta = metaText(seed, vectors[i], id, v, san);
		const dir = bundleDir(p.bundles, names[i], meta, programs[i]);
		const known = exists(dir);
		if (!known) { writeBundle(dir, p, names[i], programs[i], meta, v); }
		if (v.kind == "timeout" || v.kind == "unjudged") { notBugs++; } else { findings++; }
		console.log("  " + names[i] + " " + v.kind + (v.split == "" ? "" : " [" + v.split + "]") + (known ? " (bundle already recorded, left untouched) → " : " → ") + dir);
	}
	console.log(String(count) + " programs · " + String(clean) + " clean · " + String(findings) + " finding(s) · " +
		String(notBugs) + " timeout/unjudged (not a bug until a longer deadline or a second lane proves it)");
	return findings + notBugs > 0 ? 1 : 0;
}

function metaField(meta: string, key: string): string | null {
	for (const line of meta.split("\n")) {
		if (line.startsWith(key + ": ")) { return line.slice(key.length + 2, line.length); }
		if (line == key + ":") { return ""; }
	}
	return null;
}

function allDigits(text: string): boolean {
	if (text == "" || text.length > 15) { return false; }
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return false; }
	}
	return true;
}

function inList(list: string[], item: string): boolean {
	for (const x of list) { if (x == item) { return true; } }
	return false;
}

function parseMeta(meta: string): Result<Recorded, string> {
	const values: string[] = [];
	for (const key of REQUIRED_KEYS) {
		const v = metaField(meta, key);
		if (v === null) { return Result.err("meta.txt lacks the key '" + key + "'"); }
		if (v == "" && key != "split") { return Result.err("meta.txt has an empty '" + key + "'"); }
		values.push(v);
	}
	const seedText = values[0];
	if (!allDigits(seedText)) { return Result.err("meta.txt seed '" + seedText + "' is not a number"); }
	const fr = Features.defaults().overlay(values[1]);
	if (!fr.ok) { return Result.err("meta.txt features: " + fr.error); }
	if (!inList(FINDING_KINDS, values[2])) { return Result.err("meta.txt kind '" + values[2] + "' is not a recorded finding kind"); }
	if (values[10] != MODE_PARITY && values[10] != MODE_SAN) { return Result.err("meta.txt mode '" + values[10] + "' is not parity or san"); }
	const lanes: string[] = [];
	const laneLines: string[] = [];
	for (const line of meta.split("\n")) {
		if (!line.startsWith("lane: ")) { continue; }
		const parts = line.slice("lane: ".length, line.length).split(" ");
		if (parts.length < 2 || parts[0] == "" || (parts[1] != "pass" && parts[1] != "fail")) {
			return Result.err("meta.txt has a malformed lane line '" + line + "'");
		}
		lanes.push(parts[0]);
		laneLines.push(line);
	}
	if (lanes.length == 0) { return Result.err("meta.txt records no lane"); }
	return Result.ok({
		seed: seedText.parseInt() as uint64,
		features: fr.value,
		kind: values[2],
		split: values[3],
		msc: values[5],
		generator: values[4],
		mscHash: values[6],
		support: values[8],
		runner: values[9],
		mode: values[10],
		lanes: lanes,
		laneLines: laneLines,
	});
}

function laneSetText(lanes: string[]): string {
	const wrapped: LaneResult[] = [];
	for (const l of lanes) { wrapped.push({ lane: l, pass: true, detail: "" }); }
	let text = "";
	for (const r of sortLanes(wrapped)) { text += (text == "" ? "" : " ") + r.lane; }
	return text;
}

function laneFile(dir: string, file: string): string {
	const r = readFile(dir + "/" + file);
	return r.ok ? r.value : "<absent>";
}

function outFile(mode: string): string { return mode == MODE_SAN ? "stdout.log" : "out.log"; }

function voidBundle(label: string, cause: string): int32 {
	console.log("VOID " + label + " — " + cause);
	return 1;
}

function bundleHasLane(dir: string, lane: string): boolean {
	for (const file of CELL_FILES) { if (exists(dir + "/lanes/" + lane + "." + file)) { return true; } }
	return false;
}

export function rerunBundle(dir: string): int32 {
	const p = paths();
	const label = basename(dir);
	const metaRead = readFile(dir + "/meta.txt");
	const programRead = readFile(dir + "/program.ms");
	if (!metaRead.ok) { return voidBundle(label, "no readable meta.txt in " + dir); }
	if (!programRead.ok) { return voidBundle(label, "no readable program.ms in " + dir); }
	if (exists(p.sandbox) && (slashes(realpath(dir)) + "/").startsWith(slashes(realpath(p.sandbox)) + "/")) {
		return voidBundle(label, "the bundle lives inside the scratch sandbox that every run wipes; copy it out first");
	}
	const rec = parseMeta(metaRead.value);
	if (!rec.ok) { return voidBundle(label, rec.error); }
	const r = rec.value;
	const san = r.mode == MODE_SAN;
	const f = r.features;
	const name = programName(r.seed, f);
	const program = generate(r.seed, f);
	if (program != programRead.value) {
		const now = generatorIdentity(p.root);
		const cause = r.generator == now ? "program.ms was edited after the bundle was written" : "the generator changed since the bundle was written";
		console.log("VOID " + name + " — seed + features no longer give program.ms: " + cause);
		console.log("  bundle generator " + r.generator);
		console.log("  now    generator " + now);
		return 1;
	}
	for (const lane of r.lanes) {
		if (!bundleHasLane(dir, lane)) { return voidBundle(name, "the bundle holds no evidence files for the recorded lane " + lane); }
	}
	const msc = env.get("MSC") != "" ? subjectMsc(p.root) : r.msc;
	const id = identify(p.root, msc);
	if (id.mscHash != r.mscHash) {
		console.log("VOID " + name + " — " + msc + " is not the compiler the bundle recorded");
		console.log("  bundle msc-hash " + r.mscHash);
		console.log("  now    msc-hash " + id.mscHash);
		return 1;
	}
	if (id.support != r.support) {
		return voidBundle(name, "the support tree changed: bundle '" + r.support + "', now '" + id.support + "'");
	}
	if (id.runner != r.runner) {
		return voidBundle(name, "the corpus runner or its fixtures changed: bundle " + r.runner + ", now " + id.runner);
	}
	const stale = prepareSandbox(p);
	if (stale != "") { return fail(stale); }
	writeFile(p.programs + "/" + name + ".ms", program);
	const log = runCorpus(p, msc, san);
	if (!log.ok) { return fail(log.error); }
	const v = classify(log.value, name, p.cells, san);
	const ran: string[] = [];
	for (const x of v.lanes) { ran.push(x.lane); }
	if (laneSetText(ran) != laneSetText(r.lanes)) {
		return voidBundle(name, "the lanes that ran differ from the recorded set: bundle [" + laneSetText(r.lanes) + "], now [" + laneSetText(ran) + "]");
	}
	let diffs = "";
	if (v.kind != r.kind) { diffs += "  kind " + r.kind + " → " + v.kind + "\n"; }
	if (v.split != r.split) { diffs += "  split " + r.split + " → " + v.split + "\n"; }
	for (const x of v.lanes) {
		const recorded = "lane: " + x.lane + " " + (x.pass ? "pass" : "fail") + " " + x.detail;
		if (!inList(r.laneLines, recorded) && v.kind != "timeout") { diffs += "  lane " + x.lane + " now '" + recorded + "'\n"; }
		const now = laneFile(p.cells + "/" + name + "." + x.lane, outFile(r.mode));
		const then = laneFile(dir + "/lanes", x.lane + "." + outFile(r.mode));
		if (now != then) { diffs += "  lane " + x.lane + " " + outFile(r.mode) + " differs from the bundle\n"; }
	}
	const observed = metaText(r.seed, f, id, v, san);
	const kept = bundleDir(p.reruns, label, observed, program);
	if (!exists(kept)) { writeBundle(kept, p, name, program, observed, v); }
	if (diffs != "") {
		console.log("NOT REPRODUCED " + name + " — observation kept in " + kept);
		console.log(diffs.trimEnd());
		return 1;
	}
	console.log("REPRODUCED " + name + " — " + v.kind + (v.split == "" ? "" : " [" + v.split + "]") + ", program byte-identical, every lane output identical; observation kept in " + kept);
	return 0;
}

const SAMPLE_IDENTITY: Identity = {
	generator: "gen",
	msc: "/x/msc",
	mscHash: "h:1",
	mscVersion: "v",
	support: "BUILD abc",
	runner: "r:1",
};

function sampleMeta(san: boolean): string {
	const lanes: LaneResult[] = [{ lane: "c", pass: true, detail: "exit=0" }, { lane: "js", pass: false, detail: "exit=1 [x y]" }];
	const v: Verdict = { kind: san ? "san" : "wrong-code", split: "c | js", lanes: lanes, lines: "" };
	return metaText(7, Features.defaults(), SAMPLE_IDENTITY, v, san);
}

function withoutKey(meta: string, key: string): string {
	let out = "";
	for (const line of meta.split("\n")) {
		if (!line.startsWith(key + ":")) { out += line + "\n"; }
	}
	return out;
}

test "metadata round-trips with its mode and lanes" {
	const r = parseMeta(sampleMeta(true));
	assert r.ok;
	if (r.ok) {
		assert r.value.seed == 7 && r.value.mode == "san" && r.value.kind == "san";
		assert r.value.lanes.length == 2 && r.value.runner == "r:1" && r.value.support == "BUILD abc";
	}
	const q = parseMeta(sampleMeta(false));
	assert q.ok;
	if (q.ok) { assert q.value.mode == "parity"; }
}

test "metadata missing any required key is refused naming the key" {
	for (const key of REQUIRED_KEYS) {
		const r = parseMeta(withoutKey(sampleMeta(false), key));
		assert !r.ok;
		if (!r.ok) { assert r.error.contains("'" + key + "'"); }
	}
}

test "metadata with an empty, malformed or unknown value is refused" {
	const meta = sampleMeta(false);
	assert !parseMeta(meta.replaceAll("seed: 7", "seed: ")).ok;
	assert !parseMeta(meta.replaceAll("seed: 7", "seed: 7x")).ok;
	assert !parseMeta(meta.replaceAll("kind: wrong-code", "kind: clean")).ok;
	assert !parseMeta(meta.replaceAll("mode: parity", "mode: asan")).ok;
	assert !parseMeta(meta.replaceAll("lane: c pass", "lane: c maybe")).ok;
	assert !parseMeta(meta.replaceAll("types=", "types=int128,")).ok;
	assert !parseMeta("").ok;
}

test "metadata that records no lane is refused" {
	assert !parseMeta(withoutKey(sampleMeta(false), "lane")).ok;
}

test "a lost lane changes the lane set, whatever the order" {
	assert laneSetText(["js", "c"]) == laneSetText(["c", "js"]);
	assert laneSetText(["c", "js"]) != laneSetText(["c"]);
	assert laneSetText(["c"]) != laneSetText(["c", "raiser"]);
}

test "the SAN lane classifies a sanitizer failure as its own kind" {
	const failing = "  ✗ FAIL smith1-aa [san] — exit=1 [AddressSanitizer: heap-use-after-free]\n";
	const clean = "  ✓ smith1-aa [san] — exit=0\n";
	assert classify(failing, "smith1-aa", "/none", true).kind == "san";
	assert classify(clean, "smith1-aa", "/none", true).kind == "clean";
	assert classify("  ✗ FAIL smith1-aa [san] — exit=0 [ledger Box alloc=3 destroy=2]\n", "smith1-aa", "/none", true).kind == "san";
	assert classify("  ✗ FAIL smith1-aa [san] — exit=1 [DOUBLE-DESTROY x]\n", "smith1-aa", "/none", true).kind == "san";
	assert classify("  ✗ FAIL smith1-aa [san] — build failed — cells/x/build.log\n", "smith1-aa", "/none", true).kind == "unrated";
	assert classify("  ✗ FAIL smith1-aa [san] — exit=3 [exit≠0]\n", "smith1-aa", "/none", true).kind == "unrated";
	assert classify("  ✗ FAIL smith1-aa [san] — TIMEOUT after 60s\n", "smith1-aa", "/none", true).kind == "timeout";
	assert classify("", "smith1-aa", "/none", true).kind == "missing";
}

test "parity mode keeps its classification" {
	const log = "  ✓ smith1-aa [c] — exit=0\n  ✗ FAIL smith1-aa [js] — exit=1\n";
	assert classify(log, "smith1-aa", "/none", false).kind == "crash";
}

test "a bundle directory is addressed by its content" {
	const a = bundleDir("/b", "n", "meta one", "prog");
	assert a == bundleDir("/b", "n", "meta one", "prog");
	assert a != bundleDir("/b", "n", "meta two", "prog");
	assert a != bundleDir("/b", "n", "meta one", "prog2");
	assert a.startsWith("/b/n-");
}

test "a prepared sandbox holds no cell or runner log from an earlier run" {
	const p = pathsUnder(slashes(cwd()), slashes(cwd()) + "/out/smith/test");
	ensureDir(p.cells + "/smith9-x.c");
	writeFile(p.cells + "/smith9-x.c/out.log", "stale");
	writeFile(p.sandbox + "/runner.log", "stale");
	assert prepareSandbox(p) == "";
	assert !exists(p.cells + "/smith9-x.c/out.log");
	assert !exists(p.sandbox + "/runner.log");
}
