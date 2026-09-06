// nim-guard runner — cross-platform port of guard/run.sh (msc run src/test/guard/run.ms).
//
// Each *.ms here is a probe that exercises ONE Nim-derived invariant. It is
// built with the DRC ledger (-DMS_DRC_LEDGER, a test-only instrumentation that
// aborts on the 2nd finalize of a live object and dumps per-type alloc/destroy
// balance at exit). A guard passes iff: clean exit, no DOUBLE-DESTROY, and
// every declared per-type balance holds. A red guard means a refactor drifted
// from the Nim model the probe cites — run /trace-nim on the named type.
//
// Directives in a probe's header comments (optional):
//   // GUARD-BALANCE <MangledType>   assert alloc==destroy for that type at exit
//   // GUARD-BALANCE-ORC <MangledType>  same, but under orc only (cycle leaks are by-design under drc/ARC)
//   // GUARD-CHECK-FAIL <substr>     build MUST fail and the log MUST carry every substr
//   // GUARD-JS                      also build --target=js + node-run; pass = exit 0 + GUARD-OK printed
// The double-destroy abort needs no directive — it is name-agnostic.
//
// Env: MSC=<path to msc> (default: ./msc, else installed msc)   GUARD_GC="drc orc" (default both)
//
// Port notes vs run.sh (semantics identical, mechanics differ):
//   - Output capture goes through std/process exec() (in-memory streams), not
//     shell redirects — no POSIX-ism left, cmd.exe handles `cd "x" && "y" ...`.
//   - The build sandbox is a persistent out/guard/work instead of mktemp -d:
//     same isolation from the repo-root out/ cache race, but its object cache
//     stays warm across runs (the global ~/.metascript cache is warm either way).
//   - Probe binaries are resolved with an .exe fallback (msc on Windows writes
//     <output>.exe); shell paths get backslashes on Windows for cmd.exe's cd.
//   - Verdict lines stream to stderr; the final line also lands on stdout.
import { exec, exit, env, platform, cwd, cmdExists } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, removeAll } from "std/fs";
import { writeStderr } from "std/io";

const GUARD_DIR = "src/test/guard/";
const OUT_DIR = "out/guard/";

function progress(line: string): void {
	writeStderr(line + "\n");
}

function envOr(name: string, dflt: string): string {
	const v = env.get(name);
	return v == "" ? dflt : v;
}

// The compiler UNDER TEST — same two-tree convention as corpus/run.ms: default
// ./msc (the freshly built candidate) so a run right after a self-host build
// measures what was just built; installed msc otherwise; MSC=<path> overrides.
// Made absolute because probes build from the out/guard/work sandbox below.
function resolveMsc(): string {
	const explicit = env.get("MSC");
	if (explicit != "") { return hasSeparator(explicit) ? absolutize(explicit) : explicit; }
	if (exists("./msc")) { return absolutize("./msc"); }
	return "msc";
}

function hasSeparator(p: string): boolean {
	return p.indexOf("/") >= 0 || p.indexOf("\\") >= 0;
}

function absolutize(p: string): string {
	if (p.indexOf("/") == 0 || p.indexOf("\\") == 0 || p.indexOf(":") >= 0) { return p; }
	return cwd() + "/" + p;
}

// cmd.exe's cd wants backslashes; /bin/sh is happy either way.
function shellPath(p: string): string {
	if (platform != "windows") { return p; }
	let out = "";
	let i = 0;
	while (i < p.length) {
		const c = p.charAt(i);
		out = out + (c == "/" ? "\\" : c);
		i = i + 1;
	}
	return out;
}

// The js lane runs its bundle through `node`. Without node installed the cell
// fails to start and reports a red about the HOST, not about the backend —
// worse than no lane at all, because it reads like a JS-backend regression.
// Skip the lane and say so in the header (same call the corpus runner makes).
const HAS_NODE = cmdExists("node");

const MSC = resolveMsc();
const ROOT = cwd();
const WORK = ROOT + "/" + OUT_DIR + "work";
const BIN_DIR = ROOT + "/" + OUT_DIR + "bin";
const LOG_DIR = ROOT + "/" + OUT_DIR + "logs";

interface RunOut { exitCode: int32; signal: int32; ok: boolean; output: string; errorOutput: string; }

function runCapture(cmd: string): RunOut {
	const r = exec(cmd);
	if (r.ok) { return { exitCode: 0, signal: 0, ok: true, output: r.value, errorOutput: "" }; }
	const e = r.error;
	return { exitCode: e.exitCode as int32, signal: e.signal as int32, ok: false, output: e.output, errorOutput: e.errorOutput };
}

// ---- probe directives ----

interface Probe {
	name: string;
	path: string;
	balance: string[];
	balanceOrc: string[];
	checkfails: string[];
	wantJs: boolean;
}

// First whitespace-separated word after a directive marker — mangled type
// names are [A-Za-z0-9_]+ and never contain spaces (mirrors the awk '{print
// $NF}' in run.sh without needing char-class scans).
function firstWordAfter(s: string): string {
	const w = s.trim();
	const sp = w.indexOf(" ");
	return sp < 0 ? w : w.slice(0, sp);
}

function parseDirectives(probe: Probe, src: string): void {
	const BAL = "// GUARD-BALANCE";
	const ORC = "// GUARD-BALANCE-ORC";
	const CHECK = "// GUARD-CHECK-FAIL ";
	const JS = "// GUARD-JS";
	// A CRLF source leaves a trailing \r on every split line; riding into the
	// directive token it breaks the log contains() match against LF diagnostics.
	for (const rawLine of src.split("\n")) {
		const line = rawLine.endsWith("\r") ? rawLine.slice(0, rawLine.length - 1) : rawLine;
		const orcAt = line.indexOf(ORC);
		if (orcAt >= 0) {
			const tok = firstWordAfter(line.slice(orcAt + ORC.length, line.length));
			if (tok != "") { probe.balanceOrc.push(tok); }
		} else if (line.indexOf(BAL) >= 0) {
			const tok = firstWordAfter(line.slice(line.indexOf(BAL) + BAL.length, line.length));
			if (tok != "") { probe.balance.push(tok); }
		}
		if (line.indexOf(CHECK) == 0) {
			probe.checkfails.push(line.slice(CHECK.length, line.length));
		}
		if (line.indexOf(JS) == 0) { probe.wantJs = true; }
	}
}

function readFileOr(path: string, dflt: string): string {
	const r = readFile(path);
	if (r.ok) { return r.value; }
	return dflt;
}

// readDir order is filesystem-dependent; order only affects listing, not
// verdicts (run.sh relied on the shell glob's sort). Skip dirs, non-.ms
// entries, fixtures/ contents live in a subdir (never listed here), and this
// runner itself.
function discoverProbes(): Probe[] {
	const probes: Probe[] = [];
	for (const e of readDir(GUARD_DIR)) {
		if (e.indexOf("/") == e.length - 1) { continue; }
		if (e == "run.ms") { continue; }
		if (e.length < 4 || e.slice(e.length - 3, e.length) != ".ms") { continue; }
		const probe: Probe = {
			name: e.slice(0, e.length - 3),
			path: ROOT + "/" + GUARD_DIR + e,
			balance: [], balanceOrc: [], checkfails: [], wantJs: false,
		};
		parseDirectives(probe, readFileOr(GUARD_DIR + e, ""));
		probes.push(probe);
	}
	return probes;
}

// ---- build / run ----

// toolchain-race signatures — infra noise, not drift (same set run.sh retries
// on, plus the literal-dedup race corpus/run.ms added)
function isToolchainRace(log: string): boolean {
	return log.contains("_link.rsp': FileNotFound")
		|| log.contains("UnexpectedRemainder")
		|| log.contains("NotLibStub")
		|| log.contains("failed to resolve relocations")
		|| log.contains("failed to deduplicate literals");
}

function buildCmd(probePath: string, gc: string, binPath: string, js: boolean): string {
	const target = js ? " --target=js" : " --gc=" + gc + " --passC=\"-DMS_DRC_LEDGER\"";
	return "cd " + quote(WORK) + " && " + quote(MSC) + " build " + quote(probePath) + target + " --output=" + quote(binPath);
}

function quote(p: string): string {
	return "\"" + shellPath(p) + "\"";
}

// For a command's program token (the probe binary, node): quote only when
// needed — a cmd.exe command string must not start with a quote, and our bin
// paths normally carry no spaces.
function maybeQuote(p: string): string {
	const s = shellPath(p);
	return s.contains(" ") ? "\"" + s + "\"" : s;
}

function buildProbe(probe: Probe, gc: string, binPath: string, logPath: string, js: boolean): boolean {
	const cmd = buildCmd(probe.path, gc, binPath, js);
	let r = runCapture(cmd);
	writeFile(logPath, logText(r));
	if (!r.ok && isToolchainRace(logText(r))) {
		progress("     flake-retry " + probe.name + (js ? " [js]" : " [" + gc + "]") + ": toolchain race, rebuilding clean");
		removeAll(WORK + "/out");
		r = runCapture(cmd);
		writeFile(logPath, logText(r));
	}
	return r.ok;
}

function logText(r: RunOut): string {
	const text = r.output + r.errorOutput;
	if (r.ok || text.length > 0) { return text; }
	return "\nspawn produced no output";
}

// msc on Windows appends .exe to --output; resolve whichever exists.
function binExecutable(binPath: string): string {
	if (exists(binPath)) { return binPath; }
	if (exists(binPath + ".exe")) { return binPath + ".exe"; }
	return "";
}

function firstErrorLines(log: string): string {
	let out = "";
	let n = 0;
	for (const line of log.split("\n")) {
		if (line.indexOf("error") == 0 || line.indexOf("Error") == 0) {
			out = out + (out == "" ? "" : " | ") + line.trim();
			n = n + 1;
			if (n >= 3) { break; }
		}
	}
	return out;
}

// ---- verdicts ----

interface Tally { passes: int32; fails: int32; }

function ok(t: Tally, tag: string): void {
	t.passes = t.passes + 1;
	progress("ok   " + tag);
}

function fail(t: Tally, tag: string, why: string): void {
	t.fails = t.fails + 1;
	progress("FAIL " + tag + ": " + why);
}

// LEDGER <Type> ... alloc=N ... destroy=M (stderr, one line per type).
// Balanced iff the LAST line for the type exists and alloc == destroy.
function ledgerImbalance(errText: string, typeName: string): string {
	let last = "";
	for (const line of errText.split("\n")) {
		if (line.indexOf("LEDGER " + typeName + " ") == 0) { last = line; }
	}
	if (last == "") { return typeName + " alloc=? destroy=?"; }
	const a = fieldOf(last, "alloc=");
	const d = fieldOf(last, "destroy=");
	if (a == "" || a != d) { return typeName + " alloc=" + (a == "" ? "?" : a) + " destroy=" + (d == "" ? "?" : d); }
	return "";
}

function fieldOf(line: string, key: string): string {
	const idx = line.indexOf(key);
	if (idx < 0) { return ""; }
	const rest = line.slice(idx + key.length, line.length);
	const sp = rest.indexOf(" ");
	return sp < 0 ? rest : rest.slice(0, sp);
}

function firstLineContaining(text: string, needle: string): string {
	for (const line of text.split("\n")) {
		if (line.contains(needle)) { return line.trim(); }
	}
	return "";
}

// The gc lanes: build with the ledger, run, assert clean exit + no
// DOUBLE-DESTROY + declared balances (GUARD-BALANCE always; -ORC under orc
// only — cycle leaks are by-design under drc/ARC, like Nim).
function runGcLane(probe: Probe, gc: string, t: Tally): void {
	const tag = probe.name + " [" + gc + "]";
	const bin = BIN_DIR + "/" + probe.name + "." + gc;
	const buildLog = LOG_DIR + "/" + probe.name + "." + gc + ".build";

	if (probe.checkfails.length > 0) {
		// errorcheck guard: build MUST fail at check, log MUST carry every tag.
		// Compiling clean means a checker rule was silently dropped.
		if (buildProbe(probe, gc, bin, buildLog, false)) {
			fail(t, tag, "compiled clean — a checker rule was dropped");
			return;
		}
		const log = readFileOr(buildLog, "");
		for (const want of probe.checkfails) {
			if (!log.contains(want)) {
				fail(t, tag, "missing diagnostic: " + want);
				return;
			}
		}
		ok(t, tag);
		return;
	}

	if (!buildProbe(probe, gc, bin, buildLog, false)) {
		const errs = firstErrorLines(readFileOr(buildLog, ""));
		fail(t, tag, "build error" + (errs == "" ? "" : ": " + errs));
		return;
	}
	const exe = binExecutable(bin);
	if (exe == "") {
		fail(t, tag, "build reported success but no binary at " + bin);
		return;
	}
	// The LEDGER dump and the DOUBLE-DESTROY abort land on stderr, and exec's
	// ok path drops errorOutput — merge stderr into stdout via the shell and
	// read the combined text, or every GUARD-BALANCE check sees "".
	const run = runCapture(maybeQuote(exe) + " 2>&1");
	const errText = run.output;
	writeFile(LOG_DIR + "/" + probe.name + "." + gc + ".err", errText);
	writeFile(LOG_DIR + "/" + probe.name + "." + gc + ".out", run.output);
	const dd = firstLineContaining(errText, "DOUBLE-DESTROY");
	if (!run.ok || dd != "") {
		fail(t, tag, dd != "" ? dd : "exit=" + run.exitCode + (run.signal != 0 ? " signal=" + run.signal : ""));
		progress("     -> drift from Nim last-ref dispose model; run /trace-nim on the named type");
		return;
	}
	const eff: string[] = [];
	for (const ty of probe.balance) { eff.push(ty); }
	if (gc == "orc") { for (const ty of probe.balanceOrc) { eff.push(ty); } }
	for (const ty of eff) {
		const why = ledgerImbalance(errText, ty);
		if (why != "") {
			fail(t, tag, "imbalance " + why);
			return;
		}
	}
	ok(t, tag);
}

// // GUARD-JS: the invariant also lives in the node bundle — build for the JS
// target and run it; pass iff exit 0 AND the probe printed GUARD-OK (values
// are printed before the checks, so a red run shows what it saw). For
// errorcheck guards this is the silent-accept half: compiling clean here
// means js runs the rejected construct with no diagnostic.
function runJsLane(probe: Probe, t: Tally): void {
	const tag = probe.name + " [js]";
	const jsOut = BIN_DIR + "/" + probe.name + ".mjs.js";
	const buildLog = LOG_DIR + "/" + probe.name + ".js.build";

	if (probe.checkfails.length > 0) {
		if (buildProbe(probe, "", jsOut, buildLog, true)) {
			fail(t, tag, "compiled clean — a checker rule was dropped");
			return;
		}
		const log = readFileOr(buildLog, "");
		for (const want of probe.checkfails) {
			if (!log.contains(want)) {
				fail(t, tag, "missing diagnostic: " + want);
				return;
			}
		}
		ok(t, tag);
		return;
	}

	if (!buildProbe(probe, "", jsOut, buildLog, true)) {
		const errs = firstErrorLines(readFileOr(buildLog, ""));
		fail(t, tag, "build error" + (errs == "" ? "" : ": " + errs));
		return;
	}
	// The build half above IS the JS-backend check and runs on every host; only
	// the GUARD-OK assertion needs node. Without it the cell would report a red
	// about the HOST, so leave it unscored (the header says the lane is off) —
	// the errorcheck branch never reaches here, so those cells stay scored.
	if (!HAS_NODE) {
		progress("skip " + tag + ": node not found — built only");
		return;
	}
	const run = runCapture("node " + maybeQuote(jsOut) + " 2>&1");
	const merged = run.output + run.errorOutput;
	writeFile(LOG_DIR + "/" + probe.name + ".js.out", merged);
	if (!run.ok || !merged.contains("GUARD-OK")) {
		const lastLine = merged == "" ? "" : lastTextLine(merged);
		fail(t, tag, "exit=" + run.exitCode + (lastLine == "" ? "" : " last='" + lastLine + "'"));
		return;
	}
	ok(t, tag);
}

function lastTextLine(text: string): string {
	let last = "";
	for (const line of text.split("\n")) { if (line.trim() != "") { last = line.trim(); } }
	return last;
}

function main(): void {
	ensureDir(WORK);
	ensureDir(BIN_DIR);
	ensureDir(LOG_DIR);

	const modes: string[] = [];
	for (const m of envOr("GUARD_GC", "drc orc").split(" ")) {
		if (m != "") { modes.push(m); }
	}

	progress("nim-guard: compiler under test = " + MSC);
	if (!HAS_NODE) {
		progress("nim-guard: !! node not found — GUARD-JS probes still BUILD for the js target (the backend half is checked), but their GUARD-OK run is unscored on this host");
	}
	const t: Tally = { passes: 0, fails: 0 };

	for (const probe of discoverProbes()) {
		for (const gc of modes) {
			runGcLane(probe, gc, t);
		}
		if (probe.wantJs) { runJsLane(probe, t); }
	}

	progress("");
	const verdict = t.fails == 0
		? "nim-guard: ALL GREEN (" + t.passes + " cells)"
		: "nim-guard: FAILURES ABOVE (" + t.passes + " ok, " + t.fails + " red)";
	progress(verdict);
	console.log(verdict);
	if (t.fails > 0) { exit(1); }
}

main();
