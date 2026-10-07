import { cwd, env, execFileResult, findOnPath, platform } from "std/process";
import { copyFile, ensureDir, exists, readFile, realpath, removeAll, writeFile } from "std/fs";
import { djb2, fingerprint, hashToHex } from "std/hash";
import { Features, defaults, format, overlay, swarm } from "./features";
import { generate } from "./gen";

const GENERATOR_SOURCES: string[] = ["rng.ms", "features.ms", "gen.ms"];
const CELL_FILES: string[] = ["out.log", "done", "build.log", "err.log", "stdout.log"];

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
}

export struct Identity {
	generator: string;
	msc: string;
	mscHash: string;
	mscVersion: string;
	support: string;
}

function slashes(p: string): string { return p.replaceAll("\\", "/"); }

function fail(msg: string): int32 {
	console.log("smith: " + msg);
	return 2;
}

function paths(): Paths {
	const root = slashes(cwd());
	const sandbox = root + "/out/smith/sandbox";
	return {
		root: root,
		sandbox: sandbox,
		programs: sandbox + "/src/test/corpus/programs",
		cells: sandbox + "/out/corpus/cells",
		bundles: root + "/out/smith/bundles",
	};
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

function supportIdentity(binary: string): string {
	const dir = binary.slice(0, binary.lastIndexOf("/"));
	const build = readFile(dir + "/../BUILD");
	if (build.ok) { return "BUILD " + build.value.trim().replaceAll("\n", "; "); }
	const head = git(dir, ["rev-parse", "HEAD"]);
	if (head == "") { return "unknown: no BUILD beside the binary and not a git checkout"; }
	const dirty = git(dir, ["status", "--porcelain", "--", "src", "std", "runtime"]) != "";
	return "git " + head + (dirty ? " with uncommitted src/std/runtime" : "");
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
	};
}

export function programName(seed: uint64, f: Features): string {
	return "smith" + String(seed) + "-" + hashToHex(djb2(f.format())).slice(0, 8);
}

function prepareSandbox(p: Paths): void {
	removeAll(p.programs);
	removeAll(p.cells);
	ensureDir(p.programs);
	copyFile(p.root + "/src/test/corpus/wintime.c", p.sandbox + "/src/test/corpus/wintime.c");
}

function runCorpus(p: Paths, msc: string): Result<string, string> {
	const harness = findOnPath("msc");
	if (harness == "") { return Result.err("no installed msc on PATH to run the corpus harness"); }
	env.set("MSC", msc);
	env.set("MSCORPUS_ONLY", "");
	env.set("MSCORPUS_FILTER", "");
	env.set("MSCORPUS_SAN", "0");
	if (env.get("MSCORPUS_CELL_TIMEOUT_MS") == "") { env.set("MSCORPUS_CELL_TIMEOUT_MS", "60000"); }
	const r = execFileResult(harness, ["run", p.root + "/src/test/corpus/run.ms"], p.sandbox);
	const log = r.output + r.errorOutput;
	writeFile(p.sandbox + "/runner.log", log);
	if (!r.started) { return Result.err("the corpus harness did not start: " + harness); }
	if (!log.contains("Corpus tier — ")) {
		return Result.err("the corpus harness printed no header; its log is " + p.sandbox + "/runner.log");
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

function classify(log: string, name: string, cells: string): Verdict {
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
	if (failed == lanes.length) { return { kind: "unrated", split: passSplit(lanes), lanes: lanes, lines: lines }; }
	if (failed > 0) { return { kind: "crash", split: passSplit(lanes), lanes: lanes, lines: lines }; }
	if (parity === null) { return { kind: "unjudged", split: "", lanes: lanes, lines: lines }; }
	if (parity.pass) { return { kind: "clean", split: "", lanes: lanes, lines: lines }; }
	return { kind: "wrong-code", split: outputSplit(cells, name, lanes), lanes: lanes, lines: lines };
}

function metaText(seed: uint64, f: Features, id: Identity, v: Verdict): string {
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
		lanes;
}

function writeBundle(p: Paths, name: string, program: string, meta: string, v: Verdict): string {
	const dir = p.bundles + "/" + name;
	removeAll(dir);
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
	return dir;
}

function isFinding(kind: string): boolean { return kind != "clean"; }

export function runSeeds(first: uint64, count: int32, base: Features, swarmed: boolean): int32 {
	const p = paths();
	if (!exists(p.root + "/src/test/corpus/run.ms")) { return fail("run from the repo root: no src/test/corpus/run.ms under " + p.root); }
	const msc = subjectMsc(p.root);
	if (msc == "") { return fail("no compiler under test: set MSC, build ./msc, or install msc"); }
	const id = identify(p.root, msc);
	prepareSandbox(p);
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
	console.log("smith run — seeds " + String(first) + ".." + String(first + ((count - 1) as uint64)) + ", " + (swarmed ? "swarm over " : "") + base.format());
	console.log("  msc " + id.msc + " (" + id.mscVersion + ", " + id.mscHash + "; " + id.support + ")");
	console.log("  generator " + id.generator);
	const log = runCorpus(p, msc);
	if (!log.ok) { return fail(log.error); }
	let clean = 0;
	let findings = 0;
	let notBugs = 0;
	for (let i = 0; i < count; i++) {
		const seed = first + (i as uint64);
		const v = classify(log.value, names[i], p.cells);
		if (v.kind == "missing") { return fail("the corpus harness reported nothing for " + names[i] + "; see " + p.sandbox + "/runner.log"); }
		if (!isFinding(v.kind)) {
			clean++;
			continue;
		}
		const dir = writeBundle(p, names[i], programs[i], metaText(seed, vectors[i], id, v), v);
		if (v.kind == "timeout" || v.kind == "unjudged") { notBugs++; } else { findings++; }
		console.log("  " + names[i] + " " + v.kind + (v.split == "" ? "" : " [" + v.split + "]") + " → " + dir);
	}
	console.log(String(count) + " programs · " + String(clean) + " clean · " + String(findings) + " finding(s) · " +
		String(notBugs) + " timeout/unjudged (not a bug until a longer deadline or a second lane proves it)");
	return findings + notBugs > 0 ? 1 : 0;
}

function metaValue(meta: string, key: string): string {
	for (const line of meta.split("\n")) {
		if (line.startsWith(key + ": ")) { return line.slice(key.length + 2, line.length); }
	}
	return "";
}

function laneFile(dir: string, file: string): string {
	const r = readFile(dir + "/" + file);
	return r.ok ? r.value : "<absent>";
}

export function rerunBundle(dir: string): int32 {
	const p = paths();
	const metaRead = readFile(dir + "/meta.txt");
	const programRead = readFile(dir + "/program.ms");
	if (!metaRead.ok || !programRead.ok) { return fail(dir + " is not a bundle: it needs meta.txt and program.ms"); }
	const meta = metaRead.value;
	const seedText = metaValue(meta, "seed");
	if (seedText == "") { return fail(dir + "/meta.txt names no seed"); }
	const seed = seedText.parseInt() as uint64;
	const fr = Features.defaults().overlay(metaValue(meta, "features"));
	if (!fr.ok) { return fail(dir + "/meta.txt: " + fr.error); }
	const f = fr.value;
	const name = programName(seed, f);
	const program = generate(seed, f);
	if (program != programRead.value) {
		const then = metaValue(meta, "generator");
		const now = generatorIdentity(p.root);
		const cause = then == now ? "program.ms was edited after the bundle was written" : "the generator changed since the bundle was written";
		console.log("VOID " + name + " — seed + features no longer give program.ms: " + cause);
		console.log("  bundle generator " + then);
		console.log("  now    generator " + now);
		return 1;
	}
	const msc = env.get("MSC") != "" ? subjectMsc(p.root) : metaValue(meta, "msc");
	const id = identify(p.root, msc);
	if (id.mscHash != metaValue(meta, "msc-hash")) {
		console.log("VOID " + name + " — " + msc + " is not the compiler the bundle recorded");
		console.log("  bundle msc-hash " + metaValue(meta, "msc-hash"));
		console.log("  now    msc-hash " + id.mscHash);
		return 1;
	}
	prepareSandbox(p);
	writeFile(p.programs + "/" + name + ".ms", program);
	const log = runCorpus(p, msc);
	if (!log.ok) { return fail(log.error); }
	const v = classify(log.value, name, p.cells);
	let diffs = "";
	if (v.kind != metaValue(meta, "kind")) { diffs += "  kind " + metaValue(meta, "kind") + " → " + v.kind + "\n"; }
	if (v.split != metaValue(meta, "split")) { diffs += "  split " + metaValue(meta, "split") + " → " + v.split + "\n"; }
	for (const r of v.lanes) {
		const recorded = "lane: " + r.lane + " " + (r.pass ? "pass" : "fail") + " " + r.detail;
		if (!meta.contains(recorded + "\n") && v.kind != "timeout") { diffs += "  lane " + r.lane + " now '" + recorded + "'\n"; }
		const now = laneFile(p.cells + "/" + name + "." + r.lane, "out.log");
		const then = laneFile(dir + "/lanes", r.lane + ".out.log");
		if (now != then) { diffs += "  lane " + r.lane + " out.log differs from the bundle\n"; }
	}
	if (diffs != "") {
		console.log("NOT REPRODUCED " + name);
		console.log(diffs.trimEnd());
		return 1;
	}
	console.log("REPRODUCED " + name + " — " + v.kind + (v.split == "" ? "" : " [" + v.split + "]") + ", program byte-identical, every lane output identical");
	return 0;
}
