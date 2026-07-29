// Corpus runner — the scriptc-frame spine (msc run src/test/corpus/run.ms).
//
// Every programs/NNN-*.ms (or NNN-*/main.ms) is a standalone program whose
// contract lives in its directive head:
//
//   // @maxrss: <MB>       -> RSS cells: build+run under --gc=drc AND --gc=orc,
//                             /usr/bin/time -l, assert exit + signal + peak RSS
//   // @stdout: <substr>   -> merged output must contain <substr> (legacy native
//                             tier semantics; parity programs omit it)
//   // @exit: <n>          -> expected exit code (default 0)
//   // @xfail(<lane>): why -> known-fail for that lane; XPASS is reported LOUD
//   // @serial             -> contention-sensitive (actor/spawn): its run cells
//                             execute alone, after the parallel drain
//   // @skip-js: why       -> no JS lane; the skip list is the JS backend worklist
//
// Programs WITHOUT @maxrss are parity programs: run through C and (unless
// @skip-js) JS-on-node, outputs byte-compared. No golden files.
//
// Scheduling: msc builds are STRICTLY SERIAL (concurrent msc builds race the
// shared out/ object cache), but each build overlaps with already-built cells
// running in background slots (shell `&` + sentinel files — no PARALOCK
// surface in the runner itself). Progress streams to stderr unbuffered;
// stdout carries the final summary.
//
//   MSC=./msc msc run src/test/corpus/run.ms
//   MSCORPUS_FILTER=leak MSC=./msc msc run src/test/corpus/run.ms
//   MSCORPUS_JOBS=4  # parallel run slots (default 4)

import { exec, exit, env } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, remove, isDir } from "std/fs";
import { writeStderr } from "std/io";

const PROG_DIR = "src/test/corpus/programs/";
const OUT_DIR = "out/corpus/";

function envOr(name: string, dflt: string): string {
	const v = env.get(name);
	return v == "" ? dflt : v;
}
const MSC = envOr("MSC", "msc");
const FILTER = envOr("MSCORPUS_FILTER", "");
const RUN_SLOTS = envOr("MSCORPUS_JOBS", "4").parseInt() as int32;

interface Spec {
	name: string;
	entry: string;
	maxRssMb: float64;
	stdoutSub: string;
	expectExit: int32;
	xfailLanes: string[];
	serial: boolean;
	skipJs: boolean;
}

interface Cell {
	spec: Spec;
	lane: string;
	bin: string;
	dir: string;
	launched: boolean;
	finished: boolean;
	pass: boolean;
	detail: string;
}

interface RunOut { exitCode: int32; signal: int32; output: string; }

interface Tally { fails: int32; xfails: int32; xpasses: int32; passes: int32; }

function runCapture(cmd: string): RunOut {
	const r = exec(cmd);
	if (r.ok) { return { exitCode: 0, signal: 0, output: r.value }; }
	const e = r.error;
	return { exitCode: e.exitCode as int32, signal: e.signal as int32, output: e.output + e.errorOutput };
}

function progress(line: string): void {
	writeStderr(line + "\n");
}

function readFileOr(path: string, dflt: string): string {
	const r = readFile(path);
	if (r.ok) { return r.value; }
	return dflt;
}

// ---- directive head ----

function directiveValue(line: string, key: string): string {
	const prefix = "// " + key + ":";
	if (line.indexOf(prefix) === 0) { return line.slice(prefix.length, line.length).trim(); }
	return "";
}

function parseSpec(name: string, entry: string): Spec {
	const spec: Spec = {
		name, entry,
		maxRssMb: -1.0, stdoutSub: "", expectExit: 0,
		xfailLanes: [], serial: false, skipJs: false,
	};
	const src = readFileOr(entry, "");
	const lines = src.split("\n");
	for (const line of lines) {
		const t = line.trim();
		if (t !== "" && t.indexOf("//") !== 0) { break; }
		const rss = directiveValue(t, "@maxrss");
		if (rss !== "") { spec.maxRssMb = rss.parseInt() as float64; }
		const sub = directiveValue(t, "@stdout");
		if (sub !== "") { spec.stdoutSub = sub; }
		const ec = directiveValue(t, "@exit");
		if (ec !== "") { spec.expectExit = ec.parseInt() as int32; }
		if (t.indexOf("// @serial") === 0) { spec.serial = true; }
		if (t.indexOf("// @skip-js") === 0) { spec.skipJs = true; }
		if (t.indexOf("// @xfail(") === 0) {
			const close = t.indexOf(")");
			if (close > 10) { spec.xfailLanes.push(t.slice(10, close)); }
		}
	}
	return spec;
}

// corpus entries are NNN-topic; order by the numeric prefix (readDir order is
// filesystem-dependent, and string relational compare is not assumed here)
function entryNumber(name: string): int32 {
	const dash = name.indexOf("-");
	if (dash <= 0) { return -1; }
	return name.slice(0, dash).parseInt() as int32;
}

function sortByNumber(items: string[]): string[] {
	const out: string[] = [];
	for (const s of items) { out.push(s); }
	for (let i = 0; i < out.length; i = i + 1) {
		let min = i;
		for (let j = i + 1; j < out.length; j = j + 1) {
			if (entryNumber(out[j]) < entryNumber(out[min])) { min = j; }
		}
		if (min !== i) { const tmp = out[i]; out[i] = out[min]; out[min] = tmp; }
	}
	return out;
}

function discoverSpecs(): Spec[] {
	const specs: Spec[] = [];
	for (const e of sortByNumber(readDir(PROG_DIR))) {
		const full = PROG_DIR + e;
		let name = e;
		let entry = full;
		if (isDir(full)) {
			if (name.slice(name.length - 1, name.length) == "/") { name = name.slice(0, name.length - 1); }
			entry = full + "/main.ms";
			if (!exists(entry)) { continue; }
		} else {
			const dotMs = e.length - 3;
			if (dotMs <= 0 || e.slice(dotMs, e.length) != ".ms") { continue; }
			name = e.slice(0, dotMs);
		}
		if (entryNumber(name) < 0) { continue; }
		if (FILTER !== "" && !name.contains(FILTER)) { continue; }
		specs.push(parseSpec(name, entry));
	}
	return specs;
}

// ---- cells ----

function makeCell(spec: Spec, lane: string, bin: string): Cell {
	const dir = OUT_DIR + "cells/" + spec.name + "." + lane + "/";
	return { spec, lane, bin, dir, launched: false, finished: false, pass: false, detail: "" };
}

function isXfail(c: Cell): boolean {
	for (const l of c.spec.xfailLanes) { if (l == c.lane) { return true; } }
	return false;
}

// parse peak RSS (MB) from `/usr/bin/time -l` output (macOS prints BYTES)
function parseRssMB(output: string): float64 {
	const lines = output.split("\n");
	for (const line of lines) {
		if (line.contains("maximum resident set size")) {
			const idx = line.indexOf("maximum");
			const numStr = line.slice(0, idx).trim();
			return (numStr.parseInt() as float64) / 1048576.0;
		}
	}
	return -1.0;
}

// ---- launch / finish ----

function launchCell(c: Cell): void {
	ensureDir(c.dir);
	if (exists(c.dir + "done")) { remove(c.dir + "done"); }
	let inner = "";
	if (c.lane == "js") {
		inner = "node " + c.bin + " > " + c.dir + "out.log 2>&1";
	} else if (c.spec.maxRssMb >= 0.0) {
		inner = "/usr/bin/time -l " + c.bin + " > " + c.dir + "stdout.log 2> " + c.dir + "time.log";
	} else {
		inner = c.bin + " > " + c.dir + "out.log 2>&1";
	}
	const cmd = "( " + inner + "; echo $? > " + c.dir + "done.tmp; mv " + c.dir + "done.tmp " + c.dir + "done ) > /dev/null 2>&1 &";
	runCapture(cmd);
	c.launched = true;
}

function cellDone(c: Cell): boolean {
	return exists(c.dir + "done");
}

// exit-code file: >=128 means signal death through the shell
function readExit(c: Cell): int32 {
	return readFileOr(c.dir + "done", "-1").trim().parseInt() as int32;
}

function finishRssCell(c: Cell): void {
	const rawExit = readExit(c);
	const timeLog = readFileOr(c.dir + "time.log", "");
	const stdoutLog = readFileOr(c.dir + "stdout.log", "");
	const died = rawExit >= 128 || timeLog.contains("terminated abnormally");
	const signal = died ? rawExit - 128 : 0;
	const exitCode = died ? 0 : rawExit;
	const rssMB = parseRssMB(timeLog);

	const exitOk = signal === 0 && !died && exitCode === c.spec.expectExit;
	const merged = stdoutLog + timeLog;
	const outOk = c.spec.stdoutSub == "" || merged.contains(c.spec.stdoutSub);
	const rssOk = rssMB >= 0.0 && rssMB <= c.spec.maxRssMb;

	let detail = "rss=" + rssMB + "MB exit=" + rawExit;
	if (!exitOk) { detail = detail + " [exit≠" + c.spec.expectExit + " sig=" + signal + "]"; }
	if (!outOk) { detail = detail + " [stdout missing '" + c.spec.stdoutSub + "']"; }
	if (!rssOk) { detail = detail + " [RSS>" + c.spec.maxRssMb + "MB]"; }
	c.pass = exitOk && outOk && rssOk;
	c.detail = detail;
	c.finished = true;
}

function finishParityCell(c: Cell): void {
	const rawExit = readExit(c);
	c.pass = rawExit === c.spec.expectExit;
	c.detail = "exit=" + rawExit;
	c.finished = true;
}

// ---- reporting ----

function reportCell(c: Cell, t: Tally): void {
	const tag = c.spec.name + " [" + c.lane + "]";
	if (isXfail(c)) {
		if (c.pass) { t.xpasses = t.xpasses + 1; progress("  ? XPASS " + tag + " — " + c.detail); }
		else { t.xfails = t.xfails + 1; progress("  ▷ xfail " + tag); }
	} else {
		if (c.pass) { t.passes = t.passes + 1; progress("  ✓ " + tag + " — " + c.detail); }
		else { t.fails = t.fails + 1; progress("  ✗ FAIL " + tag + " — " + c.detail); }
	}
}

// byte-compare a finished parity group; one extra verdict line per program
function compareParityGroup(cells: Cell[], t: Tally): void {
	if (cells.length < 2) { return; }
	for (const c of cells) {
		if (!c.pass) { return; }
	}
	const base = cells[0];
	const baseOut = readFileOr(base.dir + "out.log", "");
	let same = true;
	let other = "";
	for (const c of cells) {
		if (c.lane == base.lane) { continue; }
		const o = readFileOr(c.dir + "out.log", "");
		if (o != baseOut) { same = false; other = c.lane; }
	}
	const tag = base.spec.name + " [parity]";
	if (same) { t.passes = t.passes + 1; progress("  ✓ " + tag + " — " + cells.length + " lanes identical"); }
	else { t.fails = t.fails + 1; progress("  ✗ FAIL " + tag + " — " + base.lane + " vs " + other + " outputs differ"); }
}

// ---- build plan ----

interface BuildJob { spec: Spec; lane: string; cmd: string; cell: Cell; }

function planJobs(specs: Spec[]): BuildJob[] {
	const jobs: BuildJob[] = [];
	for (const spec of specs) {
		if (spec.maxRssMb >= 0.0) {
			const modes: string[] = ["drc", "orc"];
			for (const gc of modes) {
				const bin = OUT_DIR + "bin/" + spec.name + "." + gc;
				jobs.push({ spec, lane: gc, cmd: MSC + " build " + spec.entry + " --gc=" + gc + " --output=" + bin, cell: makeCell(spec, gc, bin) });
			}
		} else {
			const cbin = OUT_DIR + "bin/" + spec.name + ".c";
			jobs.push({ spec, lane: "c", cmd: MSC + " build " + spec.entry + " --gc=drc --output=" + cbin, cell: makeCell(spec, "c", cbin) });
			if (!spec.skipJs) {
				const jsbin = "out/" + spec.name + ".js";
				jobs.push({ spec, lane: "js", cmd: MSC + " build " + spec.entry + " --target=js", cell: makeCell(spec, "js", jsbin) });
			}
		}
	}
	return jobs;
}

// ---- scheduler ----

function activeCount(running: Cell[]): int32 {
	let n = 0;
	for (const c of running) { if (c.launched && !c.finished) { n = n + 1; } }
	return n;
}

function drain(running: Cell[], t: Tally, parityDone: Cell[]): void {
	for (const c of running) {
		if (!c.launched || c.finished) { continue; }
		if (!cellDone(c)) { continue; }
		if (c.spec.maxRssMb >= 0.0) { finishRssCell(c); } else { finishParityCell(c); }
		reportCell(c, t);
		if (c.spec.maxRssMb < 0.0) { parityDone.push(c); }
	}
}

function waitForSlot(running: Cell[], t: Tally, parityDone: Cell[]): void {
	drain(running, t, parityDone);
	while (activeCount(running) >= RUN_SLOTS) {
		runCapture("sleep 0.1");
		drain(running, t, parityDone);
	}
}

function main(): void {
	ensureDir(OUT_DIR + "bin");
	ensureDir(OUT_DIR + "cells");

	const specs = discoverSpecs();
	const jobs = planJobs(specs);

	progress("");
	progress("Corpus tier — " + specs.length + " programs, " + jobs.length + " builds (msc=" + MSC + ", slots=" + RUN_SLOTS + ")");
	progress("");

	const t: Tally = { fails: 0, xfails: 0, xpasses: 0, passes: 0 };
	const running: Cell[] = [];
	const pendingSerial: Cell[] = [];
	const parityDone: Cell[] = [];

	// builds run serially in the foreground (concurrent msc builds race the
	// shared out/ cache); finished binaries run in background slots meanwhile
	for (const job of jobs) {
		const b = runCapture(job.cmd);
		const builtOk = job.lane == "js" ? b.exitCode === 0 : b.output.contains("Built");
		if (!builtOk) {
			ensureDir(job.cell.dir);
			writeFile(job.cell.dir + "build.log", b.output);
			job.cell.pass = false;
			job.cell.detail = "build failed — " + job.cell.dir + "build.log";
			job.cell.finished = true;
			reportCell(job.cell, t);
			continue;
		}
		progress("  · built " + job.spec.name + " [" + job.lane + "]");
		if (job.cell.spec.serial) {
			pendingSerial.push(job.cell);
		} else {
			waitForSlot(running, t, parityDone);
			launchCell(job.cell);
			running.push(job.cell);
		}
	}

	// drain the parallel tail
	while (activeCount(running) > 0) {
		runCapture("sleep 0.1");
		drain(running, t, parityDone);
	}

	// serial cells: one at a time on an otherwise idle machine
	for (const c of pendingSerial) {
		launchCell(c);
		while (!cellDone(c)) { runCapture("sleep 0.05"); }
		finishRssCell(c);
		reportCell(c, t);
	}

	// parity byte-compare per program (all lanes finished by now)
	for (const spec of specs) {
		if (spec.maxRssMb >= 0.0) { continue; }
		const mine: Cell[] = [];
		for (const c of parityDone) { if (c.spec.name == spec.name) { mine.push(c); } }
		compareParityGroup(mine, t);
	}

	progress("");
	const summary = t.passes + " pass · " + t.fails + " fail · " + t.xfails + " xfail · " + t.xpasses + " xpass";
	progress("  " + summary);
	console.log(summary);
	if (t.xpasses > 0) {
		console.log("NOTE: XPASS = a known-fail now passes — clear its @xfail directive");
	}
	if (t.fails > 0) { exit(1); }
}

main();
