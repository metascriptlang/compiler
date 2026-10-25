// nim-guard runner: msc run --target=raiser src/test/guard/run.ms, from the recompiler root.
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
//   // GUARD-TEST-BALANCE <MangledType>  run the file under `msc test` with the ledger and assert the balance there
//   // GUARD-CHECK-FAIL <substr>         build MUST fail and the log MUST carry every substr
//   <code> // GUARD-REFUSED              with GUARD-CHECK-FAIL, at the end of each refused line: an error must be
//                                        located on that line, so one shape that starts compiling turns the
//                                        guard red while the others still fail; `// GUARD-WARNED` likewise for a
//                                        warning. A probe whose errors sit on two or more lines must mark them;
//                                        GUARD_RECORD_SITES=1 prints the lines each build reports
//   // GUARD-JS                          also build --target=js + node-run; pass = exit 0 + GUARD-OK printed
//   // GUARD-TSAN                        also build --sanitize=thread --cc=clang + run; pass = exit 0 +
//                                        GUARD-OK printed + no ThreadSanitizer report (unscored without the toolchain)
//   // GUARD-OS <os>                     one [<os>] lane instead: build --os=<os>; with GUARD-CHECK-FAIL the
//                                        build must fail with every tag, else it must link (nothing is run)
//   // GUARD-ASAN                        with GUARD-OS bare: also build --sanitize=address --cc=clang and run on the
//                                        host; pass = exit 0 + GUARD-OK printed + no AddressSanitizer report
// Any other `// GUARD-<word>` in a probe is red, so a misspelt or unimplemented directive cannot pass silently.
// The double-destroy abort needs no directive — it is name-agnostic. A balance holds only over a
// type the probe allocated: a type with no ledger row proves nothing and is red.
//
// Env: MSC=<path to msc> (default: ./msc, else installed msc); GUARD_ONLY=<name,...> runs those
// probes only. GUARD_SELFTEST=1 runs selftest/*.ms instead: each fixture breaks one checking rule
// and names the red it must produce (`// SELFTEST-RED <substr>`); a fixture that stays green, or
// goes red for another reason, fails the run, because a check that cannot go red checks nothing.
import { execFileResult, ExecFileResult, exit, env, cwd, cmdExists, platform, arch } from "std/process";
import { readFile, writeFile, readDir, exists, ensureDir, remove, removeAll, rename, symlink } from "std/fs";

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
const SHARD = envOr("GUARD_SHARD", "0/1").split("/");
const SHARD_INDEX = SHARD[0].parseInt() as int32;
const SHARD_COUNT = SHARD.length == 2 ? SHARD[1].parseInt() as int32 : 0;
const WORK = SHARD_COUNT > 1 ? `${OUT}/work${SHARD_INDEX}` : `${OUT}/work`;
const CLAIMS = envOr("GUARD_CLAIMS", "");

function claimProbe(probe: Probe, i: int32): boolean {
	if (CLAIMS == "") return i % SHARD_COUNT == SHARD_INDEX;
	// APFS lets two processes both unlink one file successfully (measured 2026-10-25, 211-826 of
	// 3000); rename(2) stays exclusive there, so a claim is a rename, never a remove.
	return rename(`${CLAIMS}/${probe.name}`, `${CLAIMS}/taken/${probe.name}.${SHARD_INDEX}`).ok;
}
const BIN_DIR = `${OUT}/bin`;
const LOG_DIR = `${OUT}/logs`;

// Without node the js cell reports a red about the HOST, not the backend; the
// build half still runs and the GUARD-OK half is left unscored.
const HAS_NODE = cmdExists("node");

let fails = 0;
let passes = 0;
const failReasons: string[] = [];
const unscoredOs: string[] = [];
const unscoredSkips: string[] = [];
const unscoredTsan: string[] = [];
let tsanProbed = 0;

function ok(tag: string): void {
	passes = passes + 1;
	console.log(`ok   ${tag}`);
}

function fail(tag: string, why: string): void {
	fails = fails + 1;
	failReasons.push(why);
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

// A probe that prints GUARD-FAIL names its broken invariant; the bare exit status does not.
function statusWithReasons(r: ExecFileResult): string {
	const reasons = lines(r.output).filter((l) => l.startsWith("GUARD-FAIL")).slice(0, 3).map((l) => l.slice("GUARD-FAIL".length, l.length).trim());
	return reasons.length == 0 ? status(r) : `${status(r)}: ${reasons.join(" | ")}`;
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

// runtime/drc.c prints one LEDGER line per TypeInfo: same-named types of two modules give two lines.
function ledgerImbalance(text: string, typeName: string): string {
	let dump: string[] = [];
	let lastDump: string[] = [];
	for (const line of lines(text)) {
		if (line.startsWith(`LEDGER ${typeName} `)) dump.push(line);
		if (line.startsWith("LEDGER TOTAL ")) {
			lastDump = dump;
			dump = [];
		}
	}
	if (lastDump.length == 0) return `${typeName} has no ledger row: it was never allocated or its name moved, so its balance proves nothing`;
	for (const line of lastDump) {
		const a = fieldOf(line, "alloc=");
		const d = fieldOf(line, "destroy=");
		if (a == "" || a != d) return `${typeName} alloc=${a == "" ? "?" : a} destroy=${d == "" ? "?" : d}`;
	}
	return "";
}

// ---- probe directives ----

interface Probe {
	name: string;
	path: string;
	balance: string[];
	testBalance: string[];
	checkfails: string[];
	refusedLines: int32[];
	warnedLines: int32[];
	wantJs: boolean;
	wantTsan: boolean;
	wantAsan: boolean;
	os: string;
	osArgs: string[];
	selftestRed: string;
	unknownDirectives: string[];
}

const KNOWN_DIRECTIVES = ["GUARD-BALANCE", "GUARD-TEST-BALANCE", "GUARD-CHECK-FAIL", "GUARD-REFUSED", "GUARD-WARNED", "GUARD-JS", "GUARD-TSAN", "GUARD-OS", "GUARD-ASAN"];

function firstWord(s: string): string {
	const w = s.trim();
	const sp = w.indexOf(" ");
	return sp < 0 ? w : w.slice(0, sp);
}

function parseDirectives(probe: Probe, src: string): void {
	const TEST = "// GUARD-TEST-BALANCE";
	const BAL = "// GUARD-BALANCE";
	const CHECK = "// GUARD-CHECK-FAIL ";
	const OS = "// GUARD-OS ";
	const all = lines(src);
	for (let i = 0; i < all.length; i++) {
		const line = all[i];
		if (!line.trim().startsWith("//")) {
			if (line.contains("// GUARD-REFUSED")) probe.refusedLines.push((i + 1) as int32);
			if (line.contains("// GUARD-WARNED")) probe.warnedLines.push((i + 1) as int32);
		}
		const testAt = line.indexOf(TEST);
		const balAt = line.indexOf(BAL);
		if (testAt >= 0) {
			const tok = firstWord(line.slice(testAt + TEST.length, line.length));
			if (tok != "") probe.testBalance.push(tok);
		} else if (balAt >= 0) {
			const tok = firstWord(line.slice(balAt + BAL.length, line.length));
			if (tok != "") probe.balance.push(tok);
		}
		const marker = line.indexOf("// GUARD-");
		if (marker >= 0) {
			const word = firstWord(line.slice(marker + 3, line.length));
			if (!KNOWN_DIRECTIVES.includes(word)) probe.unknownDirectives.push(`${word} at line ${i + 1}`);
		}
		if (line.startsWith(CHECK)) probe.checkfails.push(line.slice(CHECK.length, line.length));
		if (line.startsWith("// SELFTEST-RED ")) probe.selftestRed = line.slice("// SELFTEST-RED ".length, line.length).trim();
		if (line.startsWith("// GUARD-JS")) probe.wantJs = true;
		if (line.startsWith("// GUARD-TSAN")) probe.wantTsan = true;
		if (line.startsWith("// GUARD-ASAN")) probe.wantAsan = true;
		if (line.startsWith(OS)) {
			for (const word of line.slice(OS.length, line.length).trim().split(" ")) {
				if (word == "") continue;
				if (probe.os == "") probe.os = word;
				else probe.osArgs.push(word);
			}
		}
	}
}

function readFileOr(path: string, dflt: string): string {
	const r = readFile(path);
	return r.ok ? r.value : dflt;
}

function discoverProbes(dir: string): Probe[] {
	const only = envOr("GUARD_ONLY", "");
	const wanted = only == "" ? [] : only.split(",");
	const names: string[] = [];
	for (const e of readDir(dir)) {
		if (e.endsWith("/") || !e.endsWith(".ms") || e == "run.ms") continue;
		const name = e.slice(0, e.length - 3);
		if (wanted.length == 0 || wanted.includes(name)) names.push(name);
	}
	names.sort();
	const probes: Probe[] = [];
	for (const name of names) {
		const probe: Probe = {
			name, path: `${dir}/${name}.ms`,
			balance: [], testBalance: [], checkfails: [], refusedLines: [], warnedLines: [], wantJs: false, wantTsan: false, wantAsan: false, os: "", osArgs: [], selftestRed: "", unknownDirectives: [],
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

function stripAnsi(text: string): string {
	let out = "";
	let i = 0;
	while (i < text.length) {
		if (text.charCodeAt(i) == 27) {
			while (i < text.length && text.charAt(i) != "m") i += 1;
			i += 1;
			continue;
		}
		out = out + text.charAt(i);
		i += 1;
	}
	return out;
}

// The source lines of `path` that the build reports a diagnostic of `severity` on.
function diagnosticLines(log: string, path: string, severity: string): int32[] {
	const out: int32[] = [];
	let current = "";
	const marker = `--> ${path}:`;
	for (const line of lines(stripAnsi(log))) {
		const t = line.trim();
		if (t.startsWith("error")) current = "error";
		else if (t.startsWith("warning")) current = "warning";
		const at = t.indexOf(marker);
		if (at < 0 || current != severity) continue;
		const rest = t.slice(at + marker.length, t.length);
		const colon = rest.indexOf(":");
		const n = (colon < 0 ? rest : rest.slice(0, colon)).parseInt() as int32;
		if (!out.includes(n)) out.push(n);
	}
	return out;
}

const RECORD_SITES = envOr("GUARD_RECORD_SITES", "") == "1";

function checkDiagnostics(probe: Probe, lane: string, tag: string, log: string): void {
	let good = true;
	for (const want of probe.checkfails) {
		if (want != "" && !log.contains(want)) {
			fail(tag, `missing diagnostic: ${want}`);
			good = false;
		}
	}
	const errorsAt = diagnosticLines(log, probe.path, "error");
	const warningsAt = diagnosticLines(log, probe.path, "warning");
	if (RECORD_SITES) console.log(`     record ${probe.name} [${lane}]: errors at ${errorsAt.join(" ")}; warnings at ${warningsAt.join(" ")}`);
	for (const n of probe.refusedLines) {
		if (!errorsAt.includes(n)) {
			fail(tag, `line ${n} is marked GUARD-REFUSED but the build reports no error there: that shape compiles`);
			good = false;
		}
	}
	for (const n of probe.warnedLines) {
		if (!warningsAt.includes(n)) {
			fail(tag, `line ${n} is marked GUARD-WARNED but the build reports no warning there`);
			good = false;
		}
	}
	if (probe.refusedLines.length == 0 && probe.warnedLines.length == 0 && errorsAt.length > 1) {
		fail(tag, `errors on ${errorsAt.length} lines (${errorsAt.join(", ")}) and none marked GUARD-REFUSED: a shape that starts compiling would go unnoticed`);
		good = false;
	}
	if (good) ok(tag);
}

function runDrcLane(probe: Probe): void {
	const tag = `${probe.name} [drc]`;
	const bin = `${BIN_DIR}/${probe.name}.drc`;
	const buildLog = `${LOG_DIR}/${probe.name}.drc.build`;
	const b = buildProbe(probe, "drc", ["build", probe.path, "--passC=-DMS_DRC_LEDGER", `--output=${bin}`], buildLog);

	if (probe.checkfails.length > 0) {
		// Compiling clean means a checker rule was silently dropped.
		if (succeeded(b)) {
			fail(tag, "compiled clean — a checker rule was dropped");
			return;
		}
		checkDiagnostics(probe, "drc", tag, both(b));
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
	writeFile(`${LOG_DIR}/${probe.name}.drc.out`, run.output);
	writeFile(`${LOG_DIR}/${probe.name}.drc.err`, run.errorOutput);
	const skipped = firstLineContaining(run.output, "GUARD-SKIP");
	if (succeeded(run) && skipped != "") {
		unscoredSkips.push(tag);
		console.log(`skip ${tag}: ${skipped.slice("GUARD-SKIP".length, skipped.length).trim()}`);
		return;
	}
	const dd = firstLineContaining(run.errorOutput, "DOUBLE-DESTROY");
	if (!succeeded(run) || dd != "") {
		fail(tag, dd != "" ? dd : statusWithReasons(run));
		console.log("     -> drift from Nim last-ref dispose model; run /trace-nim on the named type");
		return;
	}
	let good = true;
	for (const ty of probe.balance) {
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
// other probe must link. A bare binary can run; GUARD-ASAN runs it.
function runOsLane(probe: Probe): void {
	const tag = `${probe.name} [${probe.os}]`;
	const bin = `${BIN_DIR}/${probe.name}.${probe.os}`;
	const buildLog = `${LOG_DIR}/${probe.name}.${probe.os}.build`;
	if (probe.balance.length > 0 || probe.testBalance.length > 0 || probe.wantJs) {
		fail(tag, "GUARD-OS builds a binary the host cannot run; drop GUARD-BALANCE/GUARD-TEST-BALANCE/GUARD-JS");
		return;
	}
	if (probe.wantAsan && probe.os != "bare") {
		fail(tag, "GUARD-ASAN runs the binary, and only an --os=bare build runs on the host");
		return;
	}
	const args = ["build", probe.path, `--os=${probe.os}`];
	for (const arg of probe.osArgs) args.push(arg);
	args.push(`--output=${bin}`);
	const b = buildProbe(probe, probe.os, args, buildLog);
	if (!succeeded(b) && both(b).contains(`--os=${probe.os} requires `)) {
		unscoredOs.push(tag);
		console.log(`skip ${tag}: this host lacks the ${probe.os} toolchain (${buildLog})`);
		return;
	}
	if (probe.checkfails.length > 0) {
		if (succeeded(b)) {
			fail(tag, "compiled clean — a checker rule was dropped");
			return;
		}
		checkDiagnostics(probe, probe.os, tag, both(b));
		return;
	}
	if (!succeeded(b)) {
		const errs = firstErrorLines(both(b));
		fail(tag, `build error${errs == "" ? "" : ": " + errs}`);
		return;
	}
	ok(tag);
	if (probe.wantAsan) runOsAsanLane(probe);
}

// A bare binary runs on the host, where ASan refuses the overlapping copy an SBF syscall refuses.
function runOsAsanLane(probe: Probe): void {
	const tag = `${probe.name} [${probe.os} asan]`;
	const bin = `${BIN_DIR}/${probe.name}.${probe.os}.asan`;
	const b = buildProbe(probe, `${probe.os} asan`, ["build", probe.path, `--os=${probe.os}`, "--sanitize=address", "--cc=clang", `--output=${bin}`], `${LOG_DIR}/${probe.name}.${probe.os}.asan.build`);
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
	let runtimeDir = "";
	if (platform == "windows") {
		const resource = execFileResult("clang", ["-print-resource-dir"]);
		if (!succeeded(resource) || resource.output.trim() == "") {
			fail(tag, `cannot locate clang ASan runtime: ${status(resource)}`);
			return;
		}
		runtimeDir = `${slashes(resource.output.trim())}/lib/windows`;
		const runtimeArch = match (arch) {
			"amd64" => "x86_64",
			"arm64" => "aarch64",
			"i386" => "i386",
			_ => "",
		};
		if (runtimeArch == "" || !exists(`${runtimeDir}/clang_rt.asan_dynamic-${runtimeArch}.dll`)) {
			fail(tag, `missing clang ASan runtime for ${arch} in ${runtimeDir}`);
			return;
		}
	}
	const oldPath = env.get("PATH");
	if (runtimeDir != "") env.set("PATH", `${runtimeDir};${oldPath}`);
	const run = execFileResult(exe, []);
	if (runtimeDir != "") env.set("PATH", oldPath);
	const merged = both(run);
	writeFile(`${LOG_DIR}/${probe.name}.${probe.os}.asan.out`, merged);
	const report = firstLineContaining(merged, "ERROR: AddressSanitizer");
	if (report != "" || !succeeded(run) || !merged.contains("GUARD-OK")) {
		fail(tag, report != "" ? report : statusWithReasons(run));
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
		checkDiagnostics(probe, "js", tag, both(b));
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

function tsanToolchain(): boolean {
	if (tsanProbed == 0) {
		const src = `${WORK}/tsanHello.ms`;
		writeFile(src, `console.log("hi");\n`);
		const r = execFileResult(MSC, ["build", src, "--sanitize=thread", "--cc=clang", `--output=${BIN_DIR}/tsanHello`], WORK);
		tsanProbed = succeeded(r) ? 1 : 2;
	}
	return tsanProbed == 1;
}

function runTsanLane(probe: Probe): void {
	const tag = `${probe.name} [tsan]`;
	const bin = `${BIN_DIR}/${probe.name}.tsan`;
	const b = buildProbe(probe, "tsan", ["build", probe.path, "--sanitize=thread", "--cc=clang", `--output=${bin}`], `${LOG_DIR}/${probe.name}.tsan.build`);
	if (!succeeded(b)) {
		if (!tsanToolchain()) {
			unscoredTsan.push(tag);
			return;
		}
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
	const merged = both(run);
	writeFile(`${LOG_DIR}/${probe.name}.tsan.out`, merged);
	const race = firstLineContaining(merged, "WARNING: ThreadSanitizer");
	if (race != "" || !succeeded(run) || !merged.contains("GUARD-OK")) {
		fail(tag, race != "" ? race : statusWithReasons(run));
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
	const b = execFileResult(MSC, ["build", "hello_emit.ms", `--output=${dir}/hello_emit_bin`], dir);
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

// `--emit=c` after a plain build of the same entry writes the C: the project
// cache vouches for the binary, not for C it never recorded. An included
// header beside a compiled C source is what used to take the up-to-date exit.
function emitCAfterBuild(): void {
	const tag = "emitCAfterBuild";
	const dir = freshDir("emitafterbuild");
	writeFile(`${dir}/value.c`, "int readValue(void) { return 7; }
");
	writeFile(`${dir}/api.h`, "int readValue(void);
");
	writeFile(`${dir}/main.ms`, "@include(\"./api.h\");
@compile(\"./value.c\");
extern function readValue(): int32;
console.log(`${readValue()}`);
");
	// The second build is the one the project cache answers.
	for (let i = 0; i < 2; i += 1) {
		const b = execFileResult(MSC, ["build", "main.ms", `--output=${dir}/main_bin`], dir);
		if (!succeeded(b)) {
			fail(tag, "build error");
			return;
		}
	}
	if (exists(`${dir}/out/debug`)) {
		for (const f of readDir(`${dir}/out/debug`)) {
			if (f.endsWith(".c")) remove(`${dir}/out/debug/${f}`);
		}
	}
	const e = execFileResult(MSC, ["build", "main.ms", `--output=${dir}/main_bin`, "--emit=c"], dir);
	writeFile(`${LOG_DIR}/${tag}.log`, both(e));
	let wrote = 0;
	if (exists(`${dir}/out/debug`)) {
		for (const f of readDir(`${dir}/out/debug`)) {
			if (f.endsWith(".c")) wrote = wrote + 1;
		}
	}
	if (!succeeded(e) || wrote == 0) {
		fail(tag, `--emit=c after a build wrote ${wrote} C file(s): ${e.output.trim()}`);
		return;
	}
	ok(tag);
}

function isIdentCode(c: int32): boolean {
	return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95;
}

function emitsFrameDestroy(text: string, owner: string): boolean {
	const head = `dollarEnv_${owner}_shared`;
	let at = text.indexOf(head, 0);
	while (at >= 0) {
		let end = at + head.length;
		while (end < text.length && isIdentCode(text.charCodeAt(end))) end += 1;
		const ident = text.slice(at, end);
		if ((ident.endsWith("Destroy") || ident.endsWith("Destroy_")) && text.charAt(end) == "(") return true;
		at = text.indexOf(head, end);
	}
	return false;
}

function deadFrameEmitsNoHooks(): void {
	const tag = "deadFrameEmitsNoHooks";
	const dir = freshDir("deadframe");
	writeFile(`${dir}/lib.ms`, "export function used(): int32 { return 1; }\n"
		+ "export function deadClosure(label: string): () => string { let s = label; return (): string => { s = s + \"+\"; return s; }; }\n"
		+ "export async function deadAsync(label: string): Promise<string> { const s = label + \"!\"; await Promise.resolve(0); return s; }\n"
		+ "export function* deadGen(label: string): Iterator<string> { const s = label + \"?\"; yield s; yield s; }\n"
		+ "export function liveClosure(label: string): () => string { let s = label; return (): string => { s = s + \"+\"; return s; }; }\n");
	writeFile(`${dir}/main.ms`, "import { used, liveClosure } from \"./lib\";\nconst f = liveClosure(\"a\");\nconsole.log(`${used()} ${f()} ${f()}`);\n");
	const b = execFileResult(MSC, ["build", "main.ms", "--emit=c"], dir);
	writeFile(`${LOG_DIR}/${tag}.log`, both(b));
	if (!succeeded(b)) {
		fail(tag, "emit error");
		return;
	}
	let liveHooks = false;
	for (const f of readDir(`${dir}/out/debug`)) {
		if (!f.endsWith(".c")) continue;
		const text = try readFile(`${dir}/out/debug/${f}`) catch "";
		for (const owner of ["deadClosure", "deadAsync", "deadGen"]) {
			if (emitsFrameDestroy(text, owner)) {
				fail(tag, `${f} emits the frame hooks of ${owner}, which nothing calls`);
				return;
			}
		}
		if (emitsFrameDestroy(text, "liveClosure")) liveHooks = true;
	}
	if (!liveHooks) {
		fail(tag, "the frame hooks of liveClosure, which main calls, are missing");
		return;
	}
	const r = execFileResult(MSC, ["run", "main.ms"], dir);
	if (!succeeded(r) || !r.output.contains("1 a+ a++")) {
		fail(tag, `liveClosure printed '${r.output.trim()}', expected '1 a+ a++'`);
		return;
	}
	ok(tag);
}

// Nim follows only symbols into code generation: a field is never a routine,
// so a destroy hook reading `label` must not keep another module's `label()`.
function fieldNameKeepsNoRoutine(): void {
	const tag = "fieldNameKeepsNoRoutine";
	const dir = freshDir("fieldname");
	const sentinel = "routine-named-like-a-field";
	writeFile(`${dir}/lib.ms`, `export function used(): int32 { return 1; }\nexport function label(): string { return "${sentinel}"; }\n`);
	writeFile(`${dir}/main.ms`, "import { used } from \"./lib\";\ninterface Tag { label: string; }\nfunction show(t: Tag): string { return t.label; }\nconsole.log(show({ label: \"x\" }) + String(used()));\n");
	const b = execFileResult(MSC, ["build", "main.ms", "--emit=c"], dir);
	writeFile(`${LOG_DIR}/${tag}.log`, both(b));
	if (!succeeded(b)) {
		fail(tag, "emit error");
		return;
	}
	for (const f of readDir(`${dir}/out/debug`)) {
		if (!f.endsWith(".c")) continue;
		const text = try readFile(`${dir}/out/debug/${f}`) catch "";
		if (text.contains(sentinel)) {
			fail(tag, `${f} emits label() though only a field is named label`);
			return;
		}
	}
	ok(tag);
}

function routineBody(text: string, name: string): string {
	let at = text.indexOf(`int32_t ${name}__`, 0);
	while (at >= 0 && text.charAt(text.indexOf("\n", at) - 1) != "{") at = text.indexOf(`int32_t ${name}__`, at + 1);
	if (at < 0) return "";
	const end = text.indexOf("\nMS_LIB_PRIVATE ", at);
	return text.slice(at, end < 0 ? text.length : end);
}

function destroyHelper(text: string, typeInfoLine: string): string {
	const field = ".destroyFn = ";
	const at = typeInfoLine.indexOf(field, 0);
	if (at < 0) return "";
	const start = at + field.length;
	const end = typeInfoLine.indexOf(",", start);
	const slot = typeInfoLine.slice(start, end < 0 ? typeInfoLine.length : end).replace("(msDestroyProc)", "");
	const adapter = `${slot}(void* dest) { `;
	const body = text.indexOf(adapter, 0);
	if (body < 0) return slot;
	const call = body + adapter.length;
	return text.slice(call, text.indexOf("(", call));
}

function calledRoutine(caller: string, prefix: string): string {
	const at = caller.indexOf(prefix, 0);
	return at < 0 ? "" : caller.slice(at, caller.indexOf("(", at));
}

function calledBody(text: string, caller: string, prefix: string): string {
	const name = calledRoutine(caller, prefix);
	const bodies = name == "" ? [] : instanceBodies(text, name, "");
	return bodies.length == 1 ? bodies[0] : "";
}

function evictionReach(text: string, caller: string): string {
	const splice = calledBody(text, caller, "TXX_splice_");
	const shrink = splice == "" ? "" : calledBody(text, splice, "TXX_shrink_");
	return shrink == "" ? "" : splice + shrink;
}

function refArrayAcyclicEmitsPlainRelease(): void {
	const tag = "refArrayAcyclicEmitsPlainRelease";
	const dir = freshDir("refarrayfamily");
	writeFile(`${dir}/main.ms`, readFileOr(`${GUARD_DIR}/refArrayElementFamily.ms`, ""));
	const b = execFileResult(MSC, ["build", "main.ms", "--emit=c"], dir);
	writeFile(`${LOG_DIR}/${tag}.log`, both(b));
	if (!succeeded(b)) {
		fail(tag, "emit error");
		return;
	}
	let leafOps = "";
	let linkOps = "";
	let all = "";
	let acyclicCell = false;
	let cyclicCell = false;
	for (const f of readDir(`${dir}/out/debug`)) {
		if (!f.endsWith(".c")) continue;
		const text = try readFile(`${dir}/out/debug/${f}`) catch "";
		if (leafOps == "") leafOps = routineBody(text, "leafOps");
		if (linkOps == "") linkOps = routineBody(text, "linkOps");
		all = all + text;
		for (const line of lines(text)) {
			if (!line.contains("RefCellTypeInfo = {")) continue;
			const helper = destroyHelper(text, line);
			if (helper == "msAcyclicRefArrayDestroy") acyclicCell = true;
			if (helper == "msRefArrayDestroy") {
				if (!line.contains(".isCyclic = MS_TRUE")) {
					fail(tag, `an acyclic array cell is released by the cyclic helper: ${line.trim()}`);
					return;
				}
				cyclicCell = true;
			}
		}
	}
	if (!acyclicCell || !cyclicCell) {
		fail(tag, `array cells: acyclic helper ${acyclicCell}, cyclic helper ${cyclicCell}; both expected`);
		return;
	}
	const leafReach = evictionReach(all, leafOps);
	const linkReach = evictionReach(all, linkOps);
	if (leafReach == "" || linkReach == "") {
		fail(tag, `splice with an item reaches no single splice and shrink instance: leafOps ${leafReach != ""}, linkOps ${linkReach != ""}`);
		return;
	}
	for (const banned of ["msDecrefCyclic(", "msRefArraySetLen(", "msRefArraySplice3("]) {
		if (leafOps.contains(banned) || leafReach.contains(banned)) {
			fail(tag, `leafOps or the splice it calls, over an acyclic class, calls ${banned}`);
			return;
		}
	}
	if (!leafOps.contains("msAcyclicRefArraySetLen(") || !leafReach.contains("msDecref(")) {
		fail(tag, "leafOps, over an acyclic class, never releases through msAcyclicRefArraySetLen( and the splice's msDecref(");
		return;
	}
	for (const want of ["msDecrefCyclic(", "msRefArraySetLen("]) {
		if (!linkOps.contains(want)) {
			fail(tag, `linkOps, over a cyclic class, never calls ${want}`);
			return;
		}
	}
	if (!linkReach.contains("msDecrefCyclic(")) {
		fail(tag, "the splice linkOps calls, over a cyclic class, never releases through msDecrefCyclic(");
		return;
	}
	ok(tag);
}

function instanceBodies(text: string, prefix: string, elem: string): string[] {
	const bodies: string[] = [];
	for (const line of lines(text)) {
		if (!line.endsWith(") {") || line.startsWith(" ") || line.startsWith("\t")) continue;
		const open = line.indexOf("(", 0);
		const name = line.slice(line.lastIndexOf(" ", open) + 1, open);
		if (!name.startsWith(prefix) || !name.contains(elem)) continue;
		const at = text.indexOf(line, 0);
		bodies.push(text.slice(at, text.indexOf("\n}\n", at)));
	}
	return bodies;
}

function arrayRelocatesByMove(): void {
	const tag = "arrayRelocatesByMove";
	const dir = freshDir("relocate");
	writeFile(`${dir}/main.ms`, readFileOr(`${GUARD_DIR}/arrayRelocateByMove.ms`, ""));
	const b = execFileResult(MSC, ["build", "main.ms", "--emit=c"], dir);
	writeFile(`${LOG_DIR}/${tag}.log`, both(b));
	if (!succeeded(b)) {
		fail(tag, "emit error");
		return;
	}
	let text = "";
	for (const f of readDir(`${dir}/out/debug`)) {
		if (f.endsWith(".c")) text = text + (try readFile(`${dir}/out/debug/${f}`) catch "");
	}
	const cases = [["_ref_Node_", "msIncref"], ["__Cell_", "Copy("]];
	for (const c of cases) {
		for (const prefix of ["TXX_splice_", "TXX_reverse_", "TXX_shift_", "mergeRuns_", "TXX_sortBy_"]) {
			const bodies = instanceBodies(text, prefix, c[0]);
			if (bodies.length == 0) {
				fail(tag, `no ${prefix} instance over ${c[0]} emitted`);
				return;
			}
			for (const body of bodies) {
				if (body.contains(c[1])) {
					fail(tag, `${prefix} over ${c[0]} relocates by copy (${c[1]})`);
					return;
				}
			}
		}
	}
	ok(tag);
}

// M7: a value another thread can reach is counted before the call that publishes it. Over the
// emitted C of the actorArcPublishRaceFree guard, every routine that sends an actor message sets
// its Arc argument with msMsgSetPtrShared first, and every routine that submits a Promise.all task
// has taken the group's future with msAwaitGroupSetDoneFut first.
function publishCountsBeforeVisible(): void {
	const tag = "publishCountsBeforeVisible";
	const dir = freshDir("publishcount");
	writeFile(`${dir}/main.ms`, readFileOr(`${GUARD_DIR}/actorArcPublishRaceFree.ms`, ""));
	const b = execFileResult(MSC, ["build", "main.ms", "--emit=c"], dir);
	writeFile(`${LOG_DIR}/${tag}.log`, both(b));
	if (!succeeded(b)) {
		fail(tag, "emit error");
		return;
	}
	const pairs: string[][] = [["msMsgSetPtrShared(", "msActorSendOrDrop("], ["msAwaitGroupSetDoneFut(", "msSpawnTaskSubmit("]];
	const seen: int32[] = [0, 0];
	for (const f of readDir(`${dir}/out/debug`)) {
		if (!f.endsWith(".c")) continue;
		const text = try readFile(`${dir}/out/debug/${f}`) catch "";
		let name = "";
		let body = "";
		for (const line of lines(text)) {
			if (name == "") {
				if (line.endsWith(") {") && !line.startsWith(" ") && !line.startsWith("\t")) { name = line; body = ""; }
				continue;
			}
			if (line != "}") { body = body + line + "\n"; continue; }
			for (let k = 0; k < pairs.length; k += 1) {
				const publish = body.indexOf(pairs[k][1], 0);
				if (publish < 0) continue;
				if (k == 0 && !name.contains("Sink_")) continue;
				seen[k] += 1;
				const count = body.indexOf(pairs[k][0], 0);
				if (count < 0 || count > publish) {
					fail(tag, `${name.trim()} calls ${pairs[k][1]}) before ${pairs[k][0]})`);
					return;
				}
			}
			name = "";
		}
	}
	if (seen[0] < 2 || seen[1] < 1) {
		fail(tag, `publication sites found: ${seen[0]} actor sends, ${seen[1]} group submits; expected 2 and 1`);
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

function buildMsTargetProject(name: string): string {
	const dir = freshDir(name);
	writeFile(`${dir}/build.ms`, "const config = {\n\tentry: \"./main.ms\",\n\tbuild: { target: \"js\" },\n};\nexport default config;\n");
	writeFile(`${dir}/main.ms`, "extern function answer(): int32 from \"(40 + 2)\";\n"
		+ "when (js) { console.log(\"picked-js-branch \" + String(answer())); }\n"
		+ "when (c) { console.log(\"picked-c-branch\"); }\n");
	return dir;
}

function buildMsTargetDecides(): void {
	const dir = buildMsTargetProject("bmtarget");
	const bundle = `${dir}/out.js`;
	const b = execFileResult(MSC, ["build", `--output=${bundle}`], dir);
	writeFile(`${LOG_DIR}/buildMsTargetBuild.log`, both(b));
	const text = try readFile(bundle) catch "";
	if (!succeeded(b)) {
		const errs = firstErrorLines(both(b));
		fail("buildMsTargetBuild", `flagless build of a build.ms js project: ${status(b)}${errs == "" ? "" : ": " + errs}`);
	} else if (!text.contains("picked-js-branch") || text.contains("picked-c-branch")) {
		fail("buildMsTargetBuild", "the js bundle took the when (c) branch: backend was seeded c");
	} else if (HAS_NODE && !hasLine(both(execFileResult("node", [bundle])), "picked-js-branch 42")) {
		fail("buildMsTargetBuild", "the js bundle did not print 'picked-js-branch 42'");
	} else {
		ok("buildMsTargetBuild");
	}

	const c = execFileResult(MSC, ["check", "main.ms"], dir);
	writeFile(`${LOG_DIR}/buildMsTargetCheck.log`, both(c));
	if (succeeded(c)) {
		ok("buildMsTargetCheck");
	} else {
		fail("buildMsTargetCheck", `flagless check of a build.ms js project: ${firstErrorLines(both(c))}`);
	}

	const flagged = execFileResult(MSC, ["check", "--target=c", "main.ms"], dir);
	writeFile(`${LOG_DIR}/buildMsTargetFlagWins.log`, both(flagged));
	if (succeeded(flagged)) {
		fail("buildMsTargetFlagWins", "--target=c over build.ms js checked clean: the JS pattern extern was not refused");
	} else if (!both(flagged).contains("is a JS pattern and needs the JS target")) {
		fail("buildMsTargetFlagWins", `--target=c failed without the JS pattern refusal: ${firstErrorLines(both(flagged))}`);
	} else {
		ok("buildMsTargetFlagWins");
	}

	const rel = freshDir("bmrelease");
	writeFile(`${rel}/build.ms`, "const config = {\n\tentry: \"./main.ms\",\n\tbuild: { optimize: \"release\" },\n};\nexport default config;\n");
	writeFile(`${rel}/main.ms`, "console.log(1);\n");
	const d = execFileResult(MSC, ["build", "--help-defines"], rel);
	const seeded = firstLineContaining(d.output, "mode=");
	if (seeded == "mode=release") {
		ok("buildMsOptimizeSeedsMode");
	} else {
		fail("buildMsOptimizeSeedsMode", `build.ms optimize release seeded '${seeded}'`);
	}
}

function runProbe(probe: Probe): void {
	if (probe.unknownDirectives.length > 0) {
		fail(probe.name, `unknown directive ${probe.unknownDirectives.join(", ")}: the runner would ignore it and the guard would assert less than it says`);
	} else if (probe.os != "") {
		runOsLane(probe);
	} else {
		runDrcLane(probe);
		if (probe.wantJs) runJsLane(probe);
		if (probe.wantTsan) runTsanLane(probe);
		if (probe.testBalance.length > 0) runTestLane(probe);
	}
}

// Each fixture breaks one check on purpose; a check that cannot go red here passes hollow guards.
function selftest(): void {
	let bad = 0;
	const fixtures = discoverProbes(`${GUARD_DIR}/selftest`);
	for (const probe of fixtures) {
		const before = failReasons.length;
		runProbe(probe);
		const reasons = failReasons.slice(before);
		const tag = `selftest ${probe.name}`;
		if (probe.selftestRed == "") {
			bad = bad + 1;
			console.log(`BAD  ${tag}: no // SELFTEST-RED line`);
		} else if (reasons.length == 0) {
			bad = bad + 1;
			console.log(`BAD  ${tag}: stayed green, the check it breaks is hollow`);
		} else if (!reasons.some((r) => r.contains(probe.selftestRed))) {
			bad = bad + 1;
			console.log(`BAD  ${tag}: red for another reason, wanted '${probe.selftestRed}'`);
		} else {
			console.log(`red  ${tag}: as declared`);
		}
	}
	if (fixtures.length == 0) {
		bad = bad + 1;
		console.log(`BAD  selftest: no fixtures under ${GUARD_DIR}/selftest`);
	}
	console.log(bad == 0 ? `nim-guard selftest: ALL RED AS DECLARED (${fixtures.length} fixtures)` : `nim-guard selftest: ${bad} fixture(s) wrong`);
	if (bad > 0) exit(1);
}

function main(): void {
	if (SHARD_COUNT < 1 || SHARD_INDEX < 0 || SHARD_INDEX >= SHARD_COUNT) {
		console.log(`nim-guard: GUARD_SHARD must be <index>/<count> with 0 <= index < count, got '${envOr("GUARD_SHARD", "")}'`);
		exit(2);
	}
	ensureDir(WORK);
	ensureDir(BIN_DIR);
	ensureDir(LOG_DIR);
	console.log(`nim-guard: compiler under test = ${MSC}`);
	if (!HAS_NODE) {
		console.log("nim-guard: !! node not found — GUARD-JS probes still BUILD for the js target, but their GUARD-OK run is unscored on this host");
	}

	if (envOr("GUARD_SELFTEST", "") == "1") {
		selftest();
		return;
	}
	const probes = discoverProbes(GUARD_DIR);
	for (let i = 0; i < probes.length; i++) {
		const probe = probes[i];
		if (!claimProbe(probe, i)) continue;
		runProbe(probe);
		if (CLAIMS != "") writeFile(`${CLAIMS}/done/${probe.name}`, "");
	}
	if (SHARD_INDEX > 0 || envOr("GUARD_ONLY", "") != "") {
		console.log(fails == 0 ? `nim-guard: ALL GREEN (${passes} cells)` : `nim-guard: FAILURES ABOVE (${passes} ok, ${fails} red)`);
		if (fails > 0) exit(1);
		return;
	}

	helloEmitClean();
	emitCAfterBuild();
	deadFrameEmitsNoHooks();
	fieldNameKeepsNoRoutine();
	refArrayAcyclicEmitsPlainRelease();
	arrayRelocatesByMove();
	publishCountsBeforeVisible();
	buildMsTargetDecides();
	preludeGate("preludeUserModule", "gi", `${GUARD_DIR}/fixtures/preludeUserModule`, "neonGuardPreludeProbe",
		"globalImports symbol never reached the entry module", "", "");
	preludeGate("preludeSymlinkedModule", "gisym", "./gi", "neonGuardPreludeProbe",
		"globalImports symbol never reached the entry module", " — the entry was matched by spelling, not by module identity",
		`${GUARD_DIR}/fixtures/preludeUserModule.ms`);
	// A FRESH process is load-bearing: an earlier in-process prelude build warms
	// the memo and hides the recursion, so this cannot become an inline test.
	preludeGate("preludeMacroCycle", "pmc", `${GUARD_DIR}/fixtures/preludeMacroCycle/gi`, "preludeMacroCycleProbe",
		"macro-emitted declaration never reached the entry module", "", "");

	if (unscoredTsan.length > 0) {
		console.log(`nim-guard: !! ${unscoredTsan.length} GUARD-TSAN cell(s) unscored on this host (no clang TSan): ${unscoredTsan.join(", ")}`);
	}
	if (unscoredOs.length > 0) {
		console.log(`nim-guard: !! ${unscoredOs.length} GUARD-OS cell(s) unscored on this host (no toolchain): ${unscoredOs.join(", ")}`);
	}
	if (unscoredSkips.length > 0) {
		console.log(`nim-guard: !! ${unscoredSkips.length} probe cell(s) printed GUARD-SKIP and are unscored on this host: ${unscoredSkips.join(", ")}`);
	}
	const verdict = fails == 0 ? `nim-guard: ALL GREEN (${passes} cells)` : `nim-guard: FAILURES ABOVE (${passes} ok, ${fails} red)`;
	console.log(verdict);
	if (fails > 0) exit(1);
}

main();
