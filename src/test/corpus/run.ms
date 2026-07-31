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
//
// MSCORPUS_SAN=1 runs the SAN lane instead: every program built once
// (drc) with ASan + slab-off + the DRC ledger, asserting exit + @stdout +
// no ASan report + no DOUBLE-DESTROY + per-type ledger balance. Balance
// rule: fail iff 0 < destroy != alloc — a type whose destroy count is 0
// may legitimately have a NULL destroyFn (e.g. msFuture); that blind spot
// is exactly what the RSS cells backstop. @maxrss is NOT asserted under
// ASan (shadow memory inflates RSS). ASan on this platform has no leak
// sanitizer — the ledger IS the leak signal in this lane.

import { exec, exit, env } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, remove, isDir } from "std/fs";
import { writeStderr } from "std/io";

const PROG_DIR = "src/test/corpus/programs/";
const OUT_DIR = "out/corpus/";

function envOr(name: string, dflt: string): string {
	const v = env.get(name);
	return v == "" ? dflt : v;
}
// The compiler UNDER TEST — distinct from the one running this harness.
// Defaults to ./msc (the freshly built binary in the repo root) so a run right
// after a self-host build measures what was just built, together with the
// repo's own std/ and runtime/ (a compiler resolves those relative to its own
// location). Falls back to the installed msc on PATH, and MSC=<path> overrides.
// The chosen binary is printed in the header — never silent.
function resolveMsc(): string {
	const explicit = env.get("MSC");
	if (explicit != "") { return explicit; }
	if (exists("./msc")) { return "./msc"; }
	return "msc";
}
const MSC = resolveMsc();
const FILTER = envOr("MSCORPUS_FILTER", "");
const RUN_SLOTS = envOr("MSCORPUS_JOBS", "4").parseInt() as int32;
const SAN = envOr("MSCORPUS_SAN", "") == "1";
// 8M ledger-set entries: ASan quarantines freed addresses (no reuse), so the
// finalized-pointer set degrades to append-only under slab-off — the default
// 1M overflows on 3M-iteration churn programs. Overflow still aborts LOUDLY.
const SAN_PASSC = "-O0 -g -fsanitize=address -DMS_SLAB_MAX=0 -DMS_DRC_LEDGER -DMS_LEDGER_SET_SIZE=8388608u";
const SAN_PASSL = "-fsanitize=address";

interface Spec {
	name: string;
	entry: string;
	maxRssMb: float64;
	stdoutSub: string;
	expectExit: int32;
	xfailLanes: string[];
	serial: boolean;
	skipJs: boolean;
	slackTypes: string[];
	slackNs: int32[];
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

function shellOut(cmd: string): string {
	return runCapture(cmd).output.trim();
}

// A binary older than the tree reports the PREVIOUS compiler's behaviour as
// today's result — indistinguishable from a real product bug, and the more
// sessions share the tree the likelier it gets (docs/TESTGAP.md T8).
function stalenessWarning(): string {
	const path = MSC.contains("/") ? MSC : shellOut("command -v " + MSC);
	if (path == "" || !exists(path)) { return ""; }
	const mtime = shellOut("stat -f %m '" + path + "' 2>/dev/null || stat -c %Y '" + path + "' 2>/dev/null");
	const commit = shellOut("git log -1 --format=%ct -- src std runtime 2>/dev/null");
	if (mtime == "" || commit == "") { return ""; }
	const age = (commit.parseInt() - mtime.parseInt()) / 60;
	if (age <= 0) { return ""; }
	const when = shellOut("git log -1 --format=%h' '%s -- src std runtime 2>/dev/null");
	return "STALE COMPILER: " + path + " is " + age.toString() + " min older than the last commit touching src/std/runtime (" + when + ") — every verdict below describes the OLD compiler; rebuild before believing any red";
}

function laneUniverse(spec: Spec): string[] {
	if (spec.maxRssMb >= 0.0) { return ["drc", "orc", "danger", "san"]; }
	const lanes: string[] = ["c", "orc", "danger", "san"];
	if (!spec.skipJs) { lanes.push("js"); }
	return lanes;
}

function listHas(items: string[], v: string): boolean {
	for (const s of items) { if (s == v) { return true; } }
	return false;
}

function joinWith(items: string[], sep: string): string {
	let out = "";
	for (const s of items) { out = out == "" ? s : out + sep + s; }
	return out;
}

// A directive that cannot apply is a lie the runner used to keep (T9): removing
// @skip-js from an @maxrss program reads as "js lane enabled" and enables
// nothing. @xfail naming an impossible lane fails; inert @skip-js is reported
// as one aggregate because it is a design call, not per-program neglect.
function validateDirectives(specs: Spec[], t: Tally): string[] {
	const inert: string[] = [];
	for (const spec of specs) {
		const lanes = laneUniverse(spec);
		for (const lane of spec.xfailLanes) {
			if (!listHas(lanes, lane)) {
				progress("  ✗ " + spec.name + " [directives] — @xfail(" + lane + ") can never fire; this program's lanes are " + joinWith(lanes, "/"));
				t.fails = t.fails + 1;
			}
		}
		if (spec.skipJs && spec.maxRssMb >= 0.0) { inert.push(spec.name); }
	}
	return inert;
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
		slackTypes: [], slackNs: [],
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
		if (t.indexOf("// @ledger-slack(") === 0) {
			const close = t.indexOf(")");
			if (close > 17) {
				spec.slackTypes.push(t.slice(17, close));
				spec.slackNs.push(t.slice(close + 2, t.length).trim().parseInt() as int32);
			}
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
	if (c.lane == "san") {
		inner = c.bin + " > " + c.dir + "stdout.log 2> " + c.dir + "err.log";
	} else if (c.lane == "js") {
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

function firstLineContaining(text: string, needle: string): string {
	for (const line of text.split("\n")) {
		if (line.contains(needle)) { return line.trim(); }
	}
	return "";
}

// LEDGER <Type> ... alloc=N ... destroy=M (stderr, one line per type).
// Balance rule: fail iff destroy > 0 and (alloc - destroy) differs from the
// program's declared @ledger-slack for that type (default 0). Slack is
// EXACT-match: values still alive at exit (module-level globals are not
// destroyed at exit — probe-verified 2026-07-29) must be declared per type,
// and if the compiler ever starts destroying them the unused slack goes red
// like an XPASS. destroy==0 may be a NULL-destroyFn type (msFuture) — that
// blind spot belongs to the RSS lane.
function ledgerSlackFor(spec: Spec, typeName: string): int32 {
	for (let i = 0; i < spec.slackTypes.length; i = i + 1) {
		if (spec.slackTypes[i] == typeName) { return spec.slackNs[i]; }
	}
	return 0;
}

function parseLedgerFailure(err: string, spec: Spec): string {
	for (const line of err.split("\n")) {
		if (line.indexOf("LEDGER ") !== 0) { continue; }
		let typeName = "";
		let alloc = -1;
		let destroy = -1;
		let i = 0;
		for (const tok of line.split(" ")) {
			if (i === 1) { typeName = tok; }
			if (tok.indexOf("alloc=") === 0) { alloc = tok.slice(6, tok.length).parseInt() as int32; }
			if (tok.indexOf("destroy=") === 0) { destroy = tok.slice(8, tok.length).parseInt() as int32; }
			i = i + 1;
		}
		if (destroy <= 0) { continue; }
		const slack = ledgerSlackFor(spec, typeName);
		const diff = alloc - destroy;
		if (diff === slack) { continue; }
		if (slack > 0 && diff === 0) {
			return typeName + " slack unused (declared " + slack + ", diff 0) — global-destroy landed? remove @ledger-slack";
		}
		return typeName + " alloc=" + alloc + " destroy=" + destroy + (slack > 0 ? " (slack " + slack + ")" : "");
	}
	return "";
}

function finishSanCell(c: Cell): void {
	const rawExit = readExit(c);
	const stdoutLog = readFileOr(c.dir + "stdout.log", "");
	const errLog = readFileOr(c.dir + "err.log", "");
	const died = rawExit >= 128;
	const exitOk = !died && rawExit === c.spec.expectExit;
	const merged = stdoutLog + errLog;
	const outOk = c.spec.stdoutSub == "" || merged.contains(c.spec.stdoutSub);
	const asanLine = firstLineContaining(errLog, "AddressSanitizer");
	const doubleLine = firstLineContaining(errLog, "DOUBLE-DESTROY");
	const imbalance = parseLedgerFailure(errLog, c.spec);
	const ledgerLive = errLog.contains("LEDGER ");

	let detail = "exit=" + rawExit;
	if (!ledgerLive) { detail = detail + " [no LEDGER output — instrumentation dropped?]"; }
	if (!exitOk) { detail = detail + " [exit≠" + c.spec.expectExit + "]"; }
	if (!outOk) { detail = detail + " [stdout missing '" + c.spec.stdoutSub + "']"; }
	if (asanLine !== "") { detail = detail + " [" + asanLine + "]"; }
	if (doubleLine !== "") { detail = detail + " [" + doubleLine + "]"; }
	if (imbalance !== "") { detail = detail + " [ledger " + imbalance + "]"; }
	c.pass = exitOk && outOk && asanLine == "" && doubleLine == "" && imbalance == "" && ledgerLive;
	c.detail = detail;
	c.finished = true;
}

function finishCell(c: Cell): void {
	if (c.lane == "san") { finishSanCell(c); return; }
	if (c.spec.maxRssMb >= 0.0) { finishRssCell(c); return; }
	finishParityCell(c);
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

function comparableOutputOf(c: Cell): string {
	return c.spec.maxRssMb >= 0.0 ? c.dir + "stdout.log" : c.dir + "out.log";
}

// byte-compare a finished parity group; one extra verdict line per program
function compareParityGroup(cells: Cell[], t: Tally): void {
	if (cells.length < 2) { return; }
	for (const c of cells) {
		if (!c.pass) { return; }
	}
	const base = cells[0];
	const baseOut = readFileOr(comparableOutputOf(base), "");
	let same = true;
	let other = "";
	for (const c of cells) {
		if (c.lane == base.lane) { continue; }
		const o = readFileOr(comparableOutputOf(c), "");
		if (o != baseOut) { same = false; other = c.lane; }
	}
	let lanes = "";
	for (const c of cells) { lanes = lanes == "" ? c.lane : lanes + "↔" + c.lane; }
	const tag = base.spec.name + " [parity]";
	if (same) { t.passes = t.passes + 1; progress("  ✓ " + tag + " — " + lanes + " identical"); }
	else { t.fails = t.fails + 1; progress("  ✗ FAIL " + tag + " — " + base.lane + " vs " + other + " outputs differ"); }
}

// ---- build plan ----

interface BuildJob { spec: Spec; lane: string; cmd: string; cell: Cell; }

function planJobs(specs: Spec[]): BuildJob[] {
	const jobs: BuildJob[] = [];
	for (const spec of specs) {
		if (SAN) {
			const bin = OUT_DIR + "bin/" + spec.name + ".san";
			const cmd = MSC + " build " + spec.entry + " --gc=drc --cc=clang --passC=\"" + SAN_PASSC + "\" --passL=\"" + SAN_PASSL + "\" --output=" + bin;
			jobs.push({ spec, lane: "san", cmd, cell: makeCell(spec, "san", bin) });
			continue;
		}
		if (spec.maxRssMb >= 0.0) {
			const modes: string[] = ["drc", "orc"];
			for (const gc of modes) {
				const bin = OUT_DIR + "bin/" + spec.name + "." + gc;
				jobs.push({ spec, lane: gc, cmd: MSC + " build " + spec.entry + " --gc=" + gc + " --output=" + bin, cell: makeCell(spec, gc, bin) });
			}
			const dbin = OUT_DIR + "bin/" + spec.name + ".danger";
			jobs.push({ spec, lane: "danger", cmd: MSC + " build " + spec.entry + " --gc=drc --danger --cc=clang --output=" + dbin, cell: makeCell(spec, "danger", dbin) });
		} else {
			const cbin = OUT_DIR + "bin/" + spec.name + ".c";
			jobs.push({ spec, lane: "c", cmd: MSC + " build " + spec.entry + " --gc=drc --output=" + cbin, cell: makeCell(spec, "c", cbin) });
			const obin = OUT_DIR + "bin/" + spec.name + ".corc";
			jobs.push({ spec, lane: "orc", cmd: MSC + " build " + spec.entry + " --gc=orc --output=" + obin, cell: makeCell(spec, "orc", obin) });
			const dbin = OUT_DIR + "bin/" + spec.name + ".danger";
			jobs.push({ spec, lane: "danger", cmd: MSC + " build " + spec.entry + " --gc=drc --danger --cc=clang --output=" + dbin, cell: makeCell(spec, "danger", dbin) });
			if (!spec.skipJs) {
				const jsbin = "out/" + spec.name + ".js";
				jobs.push({ spec, lane: "js", cmd: MSC + " build " + spec.entry + " --target=js", cell: makeCell(spec, "js", jsbin) });
			}
		}
	}
	return jobs;
}

// ---- scheduler ----

// same infra signatures guard/run.sh retries on — a toolchain race is not a verdict
function isToolchainRace(output: string): boolean {
	return output.contains("_link.rsp': FileNotFound")
		|| output.contains("UnexpectedRemainder")
		|| output.contains("NotLibStub")
		|| output.contains("failed to resolve relocations")
		|| output.contains("failed to deduplicate literals");
}

function activeCount(running: Cell[]): int32 {
	let n = 0;
	for (const c of running) { if (c.launched && !c.finished) { n = n + 1; } }
	return n;
}

function drain(running: Cell[], t: Tally, parityDone: Cell[]): void {
	for (const c of running) {
		if (!c.launched || c.finished) { continue; }
		if (!cellDone(c)) { continue; }
		finishCell(c);
		reportCell(c, t);
		if (!SAN) { parityDone.push(c); }
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
	const mode = SAN ? "SAN lane (ASan + slab-off + DRC ledger, drc)" : "parity + RSS lanes";
	progress("Corpus tier — " + specs.length + " programs, " + jobs.length + " builds, " + mode + " (msc=" + MSC + ", slots=" + RUN_SLOTS + ")");

	const t: Tally = { fails: 0, xfails: 0, xpasses: 0, passes: 0 };

	const stale = stalenessWarning();
	if (stale != "") { progress(""); progress("  !! " + stale); }
	const inertSkipJs = validateDirectives(specs, t);
	if (inertSkipJs.length > 0) {
		progress("  !! " + inertSkipJs.length + " programs carry @skip-js under @maxrss — INERT: @maxrss programs never get a js cell, so the marker enables and disables nothing");
	}
	progress("");
	const running: Cell[] = [];
	const pendingSerial: Cell[] = [];
	const parityDone: Cell[] = [];

	// builds run serially in the foreground (concurrent msc builds race the
	// shared out/ cache); finished binaries run in background slots meanwhile
	for (const job of jobs) {
		let b = runCapture(job.cmd);
		let builtOk = job.lane == "js" ? b.exitCode === 0 : b.output.contains("Built");
		if (!builtOk && isToolchainRace(b.output)) {
			progress("  · flake-retry " + job.spec.name + " [" + job.lane + "]: toolchain race, rebuilding");
			b = runCapture(job.cmd);
			builtOk = job.lane == "js" ? b.exitCode === 0 : b.output.contains("Built");
		}
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
		finishCell(c);
		reportCell(c, t);
	}

	// parity byte-compare per program (all lanes finished by now)
	for (const spec of specs) {
		if (SAN) { continue; }
		const mine: Cell[] = [];
		for (const c of parityDone) { if (c.spec.name == spec.name) { mine.push(c); } }
		compareParityGroup(mine, t);
	}

	progress("");
	if (stale != "") { progress("  !! " + stale); progress(""); }
	const summary = t.passes + " pass · " + t.fails + " fail · " + t.xfails + " xfail · " + t.xpasses + " xpass";
	progress("  " + summary);
	console.log(summary);
	if (t.xpasses > 0) {
		console.log("NOTE: XPASS = a known-fail now passes — clear its @xfail directive");
	}
	if (t.fails > 0) { exit(1); }
}

main();
