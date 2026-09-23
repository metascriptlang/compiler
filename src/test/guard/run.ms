// nim-guard runner: msc run src/test/guard/run.ms --target=raiser, from the recompiler root.
//
// Each *.ms here is a probe that exercises ONE Nim-derived invariant. It is
// built with the DRC ledger (-DMS_DRC_LEDGER, a test-only instrumentation that
// aborts on the 2nd finalize of a live object and dumps per-type alloc/destroy
// balance at exit). A guard passes iff: clean exit, no DOUBLE-DESTROY, and
// every declared per-type balance holds. A red guard means a refactor drifted
// from the Nim model the probe cites — run /trace-nim on the named type.
//
// Directives in a probe's header comments (optional):
//   // GUARD-BALANCE <MangledType>       assert alloc==destroy for that type at exit
//   // GUARD-BALANCE-ORC <MangledType>   same, but under orc only (cycle leaks are by-design under drc/ARC)
//   // GUARD-TEST-BALANCE <MangledType>  run the file under `msc test` with the ledger and assert the balance there
//   // GUARD-CHECK-FAIL <substr>         build MUST fail and the log MUST carry every substr
//   // GUARD-JS                          also build --target=js + node-run; pass = exit 0 + GUARD-OK printed
//   // GUARD-OS <os>                     one [<os>] lane instead: build --os=<os>; with GUARD-CHECK-FAIL the
//                                        build must fail with every tag, else it must link (nothing is run)
// The double-destroy abort needs no directive — it is name-agnostic.
//
// Env: MSC=<path to msc> (default: ./msc, else installed msc)   GUARD_GC="drc orc" (default both)
import { execFileResult, ExecFileResult, exit, env, cwd, cmdExists } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, removeAll, symlink } from "std/fs";

function slashes(p: string): string {
	return p.replaceAll("\\", "/");
}

function envOr(name: string, dflt: string): string {
	const v = env.get(name);
	return v == "" ? dflt : v;
}

const ROOT = slashes(cwd());

function absolutize(p: string): string {
	const s = slashes(p);
	if (s.startsWith("/") || s.indexOf(":") >= 0) return s;
	return `${ROOT}/${s}`;
}

// The compiler UNDER TEST: ./msc (the freshly built candidate) when present,
// else the installed msc; MSC=<path> overrides. Probes read it back from $MSC.
function resolveMsc(): string {
	const explicit = env.get("MSC");
	if (explicit != "") return explicit.indexOf("/") >= 0 || explicit.indexOf("\\") >= 0 ? absolutize(explicit) : explicit;
	if (exists("./msc") || exists("./msc.exe")) return absolutize("./msc");
	return "msc";
}

const MSC = resolveMsc();
env.set("MSC", MSC);
const GUARD_DIR = `${ROOT}/src/test/guard`;
const OUT = `${ROOT}/out/guard`;
// `out/<mode>/.cache` resolves against the cwd, so probes build from a private
// sandbox: sharing the repo-root cache with a concurrent build produced link
// errors on a DIFFERENT probe every run.
const WORK = `${OUT}/work`;
const BIN_DIR = `${OUT}/bin`;
const LOG_DIR = `${OUT}/logs`;

// Without node the js cell reports a red about the HOST, not the backend; the
// build half still runs and the GUARD-OK half is left unscored.
const HAS_NODE = cmdExists("node");

let fails = 0;
let passes = 0;

function ok(tag: string): void {
	passes = passes + 1;
	console.log(`ok   ${tag}`);
}

function fail(tag: string, why: string): void {
	fails = fails + 1;
	console.log(`FAIL ${tag}: ${why}`);
}

function lines(text: string): string[] {
	const out: string[] = [];
	for (const raw of text.split("\n")) out.push(raw.endsWith("\r") ? raw.slice(0, raw.length - 1) : raw);
	return out;
}

function both(r: ExecFileResult): string {
	return r.output + r.errorOutput;
}

function succeeded(r: ExecFileResult): boolean {
	return r.started && r.pipeOk && r.exitCode == 0 && r.signal == 0;
}

function status(r: ExecFileResult): string {
	if (!r.started) return "did not start";
	return r.signal != 0 ? `signal=${r.signal}` : `exit=${r.exitCode}`;
}

function firstErrorLines(log: string): string {
	let out = "";
	let n = 0;
	for (const line of lines(log)) {
		if (line.toLowerCase().startsWith("error")) {
			out = out + (out == "" ? "" : " | ") + line.trim();
			n = n + 1;
			if (n >= 3) break;
		}
	}
	return out;
}

function hasLine(text: string, want: string): boolean {
	for (const line of lines(text)) {
		if (line == want) return true;
	}
	return false;
}

function firstLineContaining(text: string, needle: string): string {
	for (const line of lines(text)) {
		if (line.contains(needle)) return line.trim();
	}
	return "";
}

function fieldOf(line: string, key: string): string {
	const idx = line.indexOf(key);
	if (idx < 0) return "";
	const rest = line.slice(idx + key.length, line.length);
	const sp = rest.indexOf(" ");
	return sp < 0 ? rest : rest.slice(0, sp);
}

// LEDGER <Type> ... alloc=N ... destroy=M, one line per type; the LAST one counts.
function ledgerImbalance(text: string, typeName: string): string {
	let last = "";
	for (const line of lines(text)) {
		if (line.startsWith(`LEDGER ${typeName} `)) last = line;
	}
	const a = fieldOf(last, "alloc=");
	const d = fieldOf(last, "destroy=");
	if (a == "" || a != d) return `${typeName} alloc=${a == "" ? "?" : a} destroy=${d == "" ? "?" : d}`;
	return "";
}

// ---- probe directives ----

interface Probe {
	name: string;
	path: string;
	balance: string[];
	balanceOrc: string[];
	testBalance: string[];
	checkfails: string[];
	wantJs: boolean;
	os: string;
}

function firstWord(s: string): string {
	const w = s.trim();
	const sp = w.indexOf(" ");
	return sp < 0 ? w : w.slice(0, sp);
}

function parseDirectives(probe: Probe, src: string): void {
	const ORC = "// GUARD-BALANCE-ORC";
	const TEST = "// GUARD-TEST-BALANCE";
	const BAL = "// GUARD-BALANCE";
	const CHECK = "// GUARD-CHECK-FAIL ";
	const OS = "// GUARD-OS ";
	for (const line of lines(src)) {
		const orcAt = line.indexOf(ORC);
		const testAt = line.indexOf(TEST);
		const balAt = line.indexOf(BAL);
		if (orcAt >= 0) {
			const tok = firstWord(line.slice(orcAt + ORC.length, line.length));
			if (tok != "") probe.balanceOrc.push(tok);
		} else if (testAt >= 0) {
			const tok = firstWord(line.slice(testAt + TEST.length, line.length));
			if (tok != "") probe.testBalance.push(tok);
		} else if (balAt >= 0) {
			const tok = firstWord(line.slice(balAt + BAL.length, line.length));
			if (tok != "") probe.balance.push(tok);
		}
		if (line.startsWith(CHECK)) probe.checkfails.push(line.slice(CHECK.length, line.length));
		if (line.startsWith("// GUARD-JS")) probe.wantJs = true;
		if (line.startsWith(OS)) probe.os = firstWord(line.slice(OS.length, line.length));
	}
}

function readFileOr(path: string, dflt: string): string {
	const r = readFile(path);
	return r.ok ? r.value : dflt;
}

function discoverProbes(): Probe[] {
	const names: string[] = [];
	for (const e of readDir(GUARD_DIR)) {
		if (e.endsWith("/") || !e.endsWith(".ms") || e == "run.ms") continue;
		names.push(e.slice(0, e.length - 3));
	}
	names.sort();
	const probes: Probe[] = [];
	for (const name of names) {
		const probe: Probe = {
			name, path: `${GUARD_DIR}/${name}.ms`,
			balance: [], balanceOrc: [], testBalance: [], checkfails: [], wantJs: false, os: "",
		};
		parseDirectives(probe, readFileOr(probe.path, ""));
		probes.push(probe);
	}
	return probes;
}

// ---- build / run ----

function isToolchainRace(log: string): boolean {
	return log.contains("_link.rsp': FileNotFound")
		|| log.contains("UnexpectedRemainder")
		|| log.contains("NotLibStub")
		|| log.contains("failed to resolve relocations")
		|| log.contains("failed to deduplicate literals");
}

// Retries once on a toolchain-race signature so infra noise cannot be mistaken
// for drift, and says so out loud when it does.
function buildProbe(probe: Probe, lane: string, args: string[], logPath: string): ExecFileResult {
	let r = execFileResult(MSC, args, WORK);
	writeFile(logPath, both(r));
	if (!succeeded(r) && isToolchainRace(both(r))) {
		console.log(`     flake-retry ${probe.name} [${lane}]: toolchain race, rebuilding clean`);
		removeAll(`${WORK}/out`);
		r = execFileResult(MSC, args, WORK);
		writeFile(logPath, both(r));
	}
	return r;
}

function binExecutable(binPath: string): string {
	if (exists(`${binPath}.exe`)) return `${binPath}.exe`;
	if (exists(binPath)) return binPath;
	return "";
}

function checkDiagnostics(tag: string, log: string, wants: string[]): void {
	let good = true;
	for (const want of wants) {
		if (want != "" && !log.contains(want)) {
			fail(tag, `missing diagnostic: ${want}`);
			good = false;
		}
	}
	if (good) ok(tag);
}

function runGcLane(probe: Probe, gc: string): void {
	const tag = `${probe.name} [${gc}]`;
	const bin = `${BIN_DIR}/${probe.name}.${gc}`;
	const buildLog = `${LOG_DIR}/${probe.name}.${gc}.build`;
	const b = buildProbe(probe, gc, ["build", probe.path, `--gc=${gc}`, "--passC=-DMS_DRC_LEDGER", `--output=${bin}`], buildLog);

	if (probe.checkfails.length > 0) {
		// Compiling clean means a checker rule was silently dropped.
		if (succeeded(b)) {
			fail(tag, "compiled clean — a checker rule was dropped");
			return;
		}
		checkDiagnostics(tag, both(b), probe.checkfails);
		return;
	}
	if (!succeeded(b)) {
		const errs = firstErrorLines(both(b));
		fail(tag, `build error${errs == "" ? "" : ": " + errs}`);
		return;
	}
	const exe = binExecutable(bin);
	if (exe == "") {
		fail(tag, `build reported success but no binary at ${bin}`);
		return;
	}
	const run = execFileResult(exe, []);
	writeFile(`${LOG_DIR}/${probe.name}.${gc}.out`, run.output);
	writeFile(`${LOG_DIR}/${probe.name}.${gc}.err`, run.errorOutput);
	const dd = firstLineContaining(run.errorOutput, "DOUBLE-DESTROY");
	if (!succeeded(run) || dd != "") {
		fail(tag, dd != "" ? dd : status(run));
		console.log("     -> drift from Nim last-ref dispose model; run /trace-nim on the named type");
		return;
	}
	const eff: string[] = [];
	for (const ty of probe.balance) eff.push(ty);
	if (gc == "orc") {
		for (const ty of probe.balanceOrc) eff.push(ty);
	}
	let good = true;
	for (const ty of eff) {
		const why = ledgerImbalance(run.errorOutput, ty);
		if (why != "") {
			fail(tag, `imbalance ${why}`);
			good = false;
		}
	}
	if (good) ok(tag);
}

// The invariant lives in a freestanding build whose binary the host cannot run,
// so the lane only builds: an errorcheck probe must fail with every tag, any
// other probe must link.
function runOsLane(probe: Probe): void {
	const tag = `${probe.name} [${probe.os}]`;
	const bin = `${BIN_DIR}/${probe.name}.${probe.os}`;
	const buildLog = `${LOG_DIR}/${probe.name}.${probe.os}.build`;
	if (probe.balance.length > 0 || probe.balanceOrc.length > 0 || probe.testBalance.length > 0 || probe.wantJs) {
		fail(tag, "GUARD-OS builds a binary the host cannot run; drop GUARD-BALANCE/GUARD-TEST-BALANCE/GUARD-JS");
		return;
	}
	const b = buildProbe(probe, probe.os, ["build", probe.path, `--os=${probe.os}`, `--output=${bin}`], buildLog);
	if (probe.checkfails.length > 0) {
		if (succeeded(b)) {
			fail(tag, "compiled clean — a checker rule was dropped");
			return;
		}
		checkDiagnostics(tag, both(b), probe.checkfails);
		return;
	}
	if (!succeeded(b)) {
		const errs = firstErrorLines(both(b));
		fail(tag, `build error${errs == "" ? "" : ": " + errs}`);
		return;
	}
	ok(tag);
}

// The invariant also lives in the node bundle: pass iff exit 0 AND the probe
// printed GUARD-OK. For an errorcheck guard this is the silent-accept half.
function runJsLane(probe: Probe): void {
	const tag = `${probe.name} [js]`;
	const jsOut = `${BIN_DIR}/${probe.name}.mjs.js`;
	const b = buildProbe(probe, "js", ["build", probe.path, "--target=js", `--output=${jsOut}`], `${LOG_DIR}/${probe.name}.js.build`);
	if (probe.checkfails.length > 0) {
		if (succeeded(b)) {
			fail(tag, "compiled clean — a checker rule was dropped");
			return;
		}
		checkDiagnostics(tag, both(b), probe.checkfails);
		return;
	}
	if (!succeeded(b)) {
		const errs = firstErrorLines(both(b));
		fail(tag, `build error${errs == "" ? "" : ": " + errs}`);
		return;
	}
	if (!HAS_NODE) {
		console.log(`skip ${tag}: node not found — built only`);
		return;
	}
	const run = execFileResult("node", [jsOut]);
	const merged = both(run);
	writeFile(`${LOG_DIR}/${probe.name}.js.out`, merged);
	if (!succeeded(run) || !merged.contains("GUARD-OK")) {
		const all = lines(merged.trim());
		fail(tag, `${status(run)} last='${all.length > 0 ? all[all.length - 1] : ""}'`);
		return;
	}
	ok(tag);
}

// Test bodies go through the analyzer's TestDecl arm; without it every owned
// value in a test leaks and `msc test` runs with other memory semantics than
// `msc build`.
function runTestLane(probe: Probe): void {
	const tag = `${probe.name} [test]`;
	const r = execFileResult(MSC, ["test", probe.path, "--passC=-DMS_DRC_LEDGER"], WORK);
	const log = both(r);
	writeFile(`${LOG_DIR}/${probe.name}.test.log`, log);
	let good = true;
	if (!succeeded(r)) {
		fail(tag, `msc test ${status(r)}`);
		good = false;
	}
	for (const ty of probe.testBalance) {
		const why = ledgerImbalance(log, ty);
		if (why != "") {
			fail(tag, `imbalance ${why}`);
			good = false;
		}
	}
	if (good) ok(tag);
}

// ---- whole-program gates ----

function freshDir(name: string): string {
	const dir = `${OUT}/${name}`;
	removeAll(dir);
	ensureDir(dir);
	return dir;
}

// A hello-world build must carry no websocket/crypto symbols: dead-module
// pruning + edge-based hook aliveness (NIM-REF CG-1).
function helloEmitClean(): void {
	const tag = "helloEmitClean";
	const dir = freshDir("emit");
	writeFile(`${dir}/hello_emit.ms`, "console.log(\"hi\");\n");
	const b = execFileResult(MSC, ["build", "hello_emit.ms", "--gc=drc", `--output=${dir}/hello_emit_bin`], dir);
	if (!succeeded(b)) {
		fail(tag, "build error");
		return;
	}
	const nm = execFileResult("nm", [binExecutable(`${dir}/hello_emit_bin`)]);
	let hits = 0;
	for (const line of lines(nm.output)) {
		const l = line.toLowerCase();
		if (l.contains("websocket") || l.contains("mbedtls") || l.contains("psa_")) hits = hits + 1;
	}
	if (hits > 0) {
		fail(tag, `${hits} dead websocket/crypto symbols in hello binary`);
		return;
	}
	ok(tag);
}

// `msc build` never runs a `test` block, so a globalImports loader check can
// only be a gate: an inline guard test is green whatever the loader does.
function preludeGate(tag: string, name: string, globalImport: string, probeCall: string, onMissing: string, onExit: string, link: string): void {
	const dir = freshDir(name);
	if (link != "" && !symlink(link, `${dir}/gi.ms`).ok) {
		fail(tag, `cannot create the symlink ${dir}/gi.ms -> ${link}`);
		return;
	}
	writeFile(`${dir}/build.ms`, `const config = {\n\tglobalImports: ["${globalImport}"],\n};\nexport default config;\n`);
	writeFile(`${dir}/main.ms`, `console.log(${probeCall}());\n`);
	const r = execFileResult(MSC, ["run", "main.ms"], dir);
	writeFile(`${LOG_DIR}/${tag}.log`, both(r));
	if (!succeeded(r)) {
		const errs = firstErrorLines(both(r));
		fail(tag, `${status(r)}${onExit}${errs == "" ? "" : ": " + errs}`);
		return;
	}
	if (!hasLine(r.output, "42")) {
		fail(tag, onMissing);
		return;
	}
	ok(tag);
}

function main(): void {
	ensureDir(WORK);
	ensureDir(BIN_DIR);
	ensureDir(LOG_DIR);
	const modes: string[] = [];
	for (const m of envOr("GUARD_GC", "drc orc").split(" ")) {
		if (m != "") modes.push(m);
	}
	console.log(`nim-guard: compiler under test = ${MSC}`);
	if (!HAS_NODE) {
		console.log("nim-guard: !! node not found — GUARD-JS probes still BUILD for the js target, but their GUARD-OK run is unscored on this host");
	}

	for (const probe of discoverProbes()) {
		if (probe.os != "") {
			runOsLane(probe);
			continue;
		}
		for (const gc of modes) runGcLane(probe, gc);
		if (probe.wantJs) runJsLane(probe);
		if (probe.testBalance.length > 0) runTestLane(probe);
	}

	helloEmitClean();
	preludeGate("preludeUserModule", "gi", `${GUARD_DIR}/fixtures/preludeUserModule`, "neonGuardPreludeProbe",
		"globalImports symbol never reached the entry module", "", "");
	preludeGate("preludeSymlinkedModule", "gisym", "./gi", "neonGuardPreludeProbe",
		"globalImports symbol never reached the entry module", " — the entry was matched by spelling, not by module identity",
		`${GUARD_DIR}/fixtures/preludeUserModule.ms`);
	// A FRESH process is load-bearing: an earlier in-process prelude build warms
	// the memo and hides the recursion, so this cannot become an inline test.
	preludeGate("preludeMacroCycle", "pmc", `${GUARD_DIR}/fixtures/preludeMacroCycle/gi`, "preludeMacroCycleProbe",
		"macro-emitted declaration never reached the entry module", "", "");

	const verdict = fails == 0 ? `nim-guard: ALL GREEN (${passes} cells)` : `nim-guard: FAILURES ABOVE (${passes} ok, ${fails} red)`;
	console.log(verdict);
	if (fails > 0) exit(1);
}

main();
