// Flow A/B runner — one table per program from every instrument (msc run src/test/perf/run.ms).
//
// Each instrument appends `<source>\t<flow>\t<metric>\t<value>` rows to a file
// (source msc | drc | emit | proc; metric ms | instr | count | bytes). This runner
// runs a base and a candidate compiler over the same programs, reads the rows of
// every run and prints, per program, the flows sorted by how far they moved.
//
//   MSPERF_BASE=<msc>       compiler A (required unless MSPERF_SELF=1)
//   MSPERF_SELF=1           candidate for both arms: the noise check
//   MSPERF_CAND=<msc>       compiler B (default ./msc when it exists, else msc on PATH)
//   MSPERF_PROGRAMS=a,b     default 711,fmt
//                             711        src/test/corpus/programs/711-jsxParseNative.ms
//                             fmt        src/test/fmt/run.ms
//                             self       src/index.ms
//                             rt:<name>  src/test/perf/programs/<name>.ms, built once per
//                                        arm with -DMS_DRC_STAT, then the binary is measured
//                           the first three are measured as `build --emit=c`
//   MSPERF_RUNS=N           runs per arm (default 3), arms interleaved in shuffled order
//   MSPERF_OUT=<dir>        raw rows and tables (default out/perf/<timestamp>)
//   MSPERF_FIXTURES=<dir>   measure nothing, tabulate <dir>/<program>.<base|cand>.<n>.tsv
//
// Every run starts in a fresh directory with MSC_NO_GLOBAL_CACHE=1 and is refused when
// it printed "Up to date": a cache hit measures nothing.
//
// Marks: `=` an exact count identical in every run of both arms; `≠` an exact count that
// changed; `*` a timed delta over 3x noise (max CV of the two arms) and over 1%; `new` / `gone` a
// flow only one arm wrote. Process totals come from /usr/bin/time -l on macOS
// (instructions retired), `perf stat` on Linux when it exists, else /usr/bin/time -f.

import { exec, exit, env, cmdExists } from "std/process";
import { readFile, writeFile, exists } from "std/fs";
import { writeStderr } from "std/io";

const NOISE_FACTOR = 3.0;
const NOISE_FLOOR_PERCENT = 1.0;

function envOr(name: string, dflt: string): string {
	const v = env.get(name);
	return v == "" ? dflt : v;
}

function progress(line: string): void {
	writeStderr(line + "\n");
}

function shellOut(cmd: string): string {
	const r = exec(cmd);
	return r.ok ? r.value.trim() : "";
}

function q(s: string): string {
	return "'" + s + "'";
}

function fail(msg: string): void {
	progress("perf: " + msg);
	exit(1);
}

function readOr(path: string, dflt: string): string {
	const r = readFile(path);
	return r.ok ? r.value : dflt;
}

// ---- statistics --------------------------------------------------------------

function sortedCopy(xs: float64[]): float64[] {
	const out: float64[] = [];
	for (const x of xs) {
		let i = out.length;
		out.push(x);
		while (i > 0 && out[i - 1] > x) {
			out[i] = out[i - 1];
			i -= 1;
		}
		out[i] = x;
	}
	return out;
}

function median(xs: float64[]): float64 {
	const s = sortedCopy(xs);
	const n = s.length;
	const mid = (n - n % 2) / 2;
	return n % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function cvPercent(xs: float64[]): float64 {
	let sum = 0.0;
	for (const x of xs) { sum += x; }
	const mean = sum / xs.length;
	if (mean == 0) { return 0; }
	let sq = 0.0;
	for (const x of xs) { sq += (x - mean) * (x - mean); }
	return Math.abs(Math.sqrt(sq / xs.length) / mean) * 100;
}

function isFlat(xs: float64[]): boolean {
	for (const x of xs) { if (x != xs[0]) { return false; } }
	return true;
}

// ---- rows --------------------------------------------------------------------

interface Arm {
	keys: string[];
	vals: Map<string, float64[]>;
}

function loadRun(arm: Arm, path: string): void {
	const r = readFile(path);
	if (!r.ok) { fail("cannot read " + path + ": " + r.error.message); return; }
	const sums = new Map<string, float64>();
	const order: string[] = [];
	const lines = r.value.split("\n");
	for (let i = 0; i < lines.length; i++) {
		if (lines[i].trim() == "") { continue; }
		const f = lines[i].split("\t");
		const v = f.length == 4 ? f[3].parseFloat() : 0.0;
		if (f.length != 4 || v != v) { fail(`${path}:${i + 1}: not a source/flow/metric/value row: ${lines[i]}`); return; }
		const key = f[0] + "\t" + f[1] + "\t" + f[2];
		if (!sums.has(key)) { order.push(key); sums.set(key, 0.0); }
		sums.set(key, sums.get(key)! + v);
	}
	for (const key of order) {
		if (!arm.vals.has(key)) { arm.keys.push(key); arm.vals.set(key, []); }
		arm.vals.get(key)!.push(sums.get(key)!);
	}
}

function loadArm(dir: string, program: string, name: string, runs: int32): Arm {
	const arm: Arm = { keys: [], vals: new Map<string, float64[]>() };
	for (let r = 1; r <= runs; r++) { loadRun(arm, `${dir}/${program}.${name}.${r}.tsv`); }
	return arm;
}

function sourcesOf(arm: Arm): string {
	const seen: string[] = [];
	for (const key of arm.keys) {
		const s = key.split("\t")[0];
		if (!seen.includes(s)) { seen.push(s); }
	}
	return seen.join(" ");
}

// ---- comparison --------------------------------------------------------------

struct Line {
	key: string;
	metric: string;
	base: float64;
	cand: float64;
	delta: float64;
	pct: float64;
	noise: float64;
	mark: string;
}

function isExact(source: string, metric: string): boolean {
	return metric == "count" || (metric == "bytes" && source != "proc");
}

function tierOf(metric: string): int32 {
	return metric == "instr" ? 0 : metric == "count" ? 1 : 2;
}

function markFor(key: string, bv: float64[], cv: float64[], runs: int32, delta: float64, pct: float64, noise: float64, baseMedian: float64): string {
	const f = key.split("\t");
	if (isExact(f[0], f[2]) && bv.length == runs && cv.length == runs && isFlat(bv) && isFlat(cv)) {
		return bv[0] == cv[0] ? "=" : "≠";
	}
	if (delta == 0) { return ""; }
	if (baseMedian == 0 || Math.abs(pct) > Math.max(NOISE_FACTOR * noise, NOISE_FLOOR_PERCENT)) { return "*"; }
	return "";
}

function compare(base: Arm, cand: Arm, runs: int32): Line[] {
	const keys: string[] = [];
	for (const k of base.keys) { keys.push(k); }
	for (const k of cand.keys) { if (!base.vals.has(k)) { keys.push(k); } }
	const out: Line[] = [];
	for (const key of keys) {
		const metric = key.split("\t")[2];
		if (!cand.vals.has(key)) {
			out.push({ key: key, metric: metric, base: median(base.vals.get(key)!), cand: 0, delta: 0, pct: 0, noise: 0, mark: "gone" });
			continue;
		}
		if (!base.vals.has(key)) {
			out.push({ key: key, metric: metric, base: 0, cand: median(cand.vals.get(key)!), delta: 0, pct: 0, noise: 0, mark: "new" });
			continue;
		}
		const bv = base.vals.get(key)!;
		const cv = cand.vals.get(key)!;
		const b = median(bv);
		const c = median(cv);
		const delta = c - b;
		const pct = b == 0 ? 0.0 : delta / b * 100;
		const noise = Math.max(cvPercent(bv), cvPercent(cv));
		out.push({ key: key, metric: metric, base: b, cand: c, delta: delta, pct: pct, noise: noise, mark: markFor(key, bv, cv, runs, delta, pct, noise, b) });
	}
	return out;
}

function ranksBefore(a: Line, b: Line): boolean {
	const ta = tierOf(a.metric);
	const tb = tierOf(b.metric);
	if (ta != tb) { return ta < tb; }
	return Math.abs(a.delta) > Math.abs(b.delta);
}

function ranked(lines: Line[]): Line[] {
	const out: Line[] = [];
	for (const l of lines) {
		let i = out.length;
		out.push(l);
		while (i > 0 && ranksBefore(l, out[i - 1])) {
			out[i] = out[i - 1];
			i -= 1;
		}
		out[i] = l;
	}
	return out;
}

// ---- coverage ----------------------------------------------------------------

function medianOf(arm: Arm, key: string): float64 {
	return arm.vals.has(key) ? median(arm.vals.get(key)!) : 0.0;
}

// phase.A's leaves: a2.xform and a2.native are split into pass.* rows, a2.analyze into analyze.* rows.
const PHASE_A_LEAVES = ["a2.mono", "a2.macro", "a2.lower"];

function coverage(arm: Arm): string {
	const phaseA = medianOf(arm, "msc\tphase.A\tinstr");
	const total = medianOf(arm, "msc\ttotal\tinstr");
	let leaves = 0.0;
	let phases = 0.0;
	for (const key of arm.keys) {
		const f = key.split("\t");
		if (f[0] != "msc" || f[2] != "instr") { continue; }
		const v = medianOf(arm, key);
		if (f[1].startsWith("pass.") || f[1].startsWith("analyze.") || PHASE_A_LEAVES.includes(f[1])) { leaves += v; }
		if (f[1].startsWith("phase.")) { phases += v; }
	}
	const a = phaseA > 0 ? percentText(leaves / phaseA * 100) : "n/a";
	const b = total > 0 ? percentText(phases / total * 100) : "n/a";
	return `leaf flows / phase.A instr ${a} · phase.* / msc total instr ${b}`;
}

// ---- rendering ---------------------------------------------------------------

function group(n: int64): string {
	const neg = n < 0;
	let rest = neg ? -n : n;
	if (rest == 0) { return "0"; }
	let s = "";
	let digits = 0;
	while (rest > 0) {
		if (digits > 0 && digits % 3 == 0) { s = "," + s; }
		s = ((rest % 10) as int32).toString() + s;
		rest = rest / 10;
		digits += 1;
	}
	return neg ? "-" + s : s;
}

function tenths(x: float64): string {
	const t = Math.round(x * 10) as int64;
	const a = t < 0 ? -t : t;
	return (t < 0 ? "-" : "") + group(a / 10) + "." + ((a % 10) as int32).toString();
}

function percentText(x: float64): string {
	return tenths(x) + "%";
}

function signed(s: string, x: float64): string {
	return x > 0 ? "+" + s : s;
}

function value(x: float64, metric: string): string {
	return metric == "ms" ? tenths(x) : group(Math.round(x) as int64);
}

function pad(s: string, n: int32, left: boolean): string {
	return left ? s.padStart(n, " ") : s.padEnd(n, " ");
}

function render(lines: Line[]): string {
	const head = ["flow", "base", "cand", "delta", "delta%", "noise", ""];
	const rows: string[][] = [head];
	for (const l of ranked(lines)) {
		const f = l.key.split("\t");
		const name = f[0] + " " + f[1] + " " + f[2];
		const hasBoth = l.mark != "new" && l.mark != "gone";
		rows.push([
			name,
			l.mark == "new" ? "-" : value(l.base, l.metric),
			l.mark == "gone" ? "-" : value(l.cand, l.metric),
			hasBoth ? signed(value(l.delta, l.metric), l.delta) : "",
			hasBoth && l.base != 0 ? signed(percentText(l.pct), l.pct) : "",
			hasBoth ? percentText(l.noise) : "",
			l.mark,
		]);
	}
	const widths: int32[] = [];
	for (let c = 0; c < head.length; c++) {
		let w = 0;
		for (const r of rows) { if (r[c].length > w) { w = r[c].length; } }
		widths.push(w);
	}
	const out: string[] = [];
	for (const r of rows) {
		let line = "";
		for (let c = 0; c < head.length; c++) { line += pad(r[c], widths[c], c > 0 && c < 6) + "  "; }
		out.push(line.trimEnd());
	}
	return out.join("\n");
}

function tableFor(dir: string, program: string, runs: int32): string {
	const base = loadArm(dir, program, "base", runs);
	const cand = loadArm(dir, program, "cand", runs);
	return `== ${program}\n` +
		`base sources: ${sourcesOf(base)}\ncand sources: ${sourcesOf(cand)}\n` +
		`coverage base: ${coverage(base)}\ncoverage cand: ${coverage(cand)}\n` +
		render(compare(base, cand, runs)) + "\n";
}

// ---- measuring ---------------------------------------------------------------

function absPath(p: string): string {
	return shellOut(`p=$(command -v ${q(p)}); echo "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"`);
}

function absDir(p: string): string {
	return shellOut(`mkdir -p ${q(p)} && cd ${q(p)} && pwd -P`);
}

function timerFor(kernel: string, timeFile: string): string {
	if (kernel == "Darwin") { return `/usr/bin/time -l -o ${q(timeFile)}`; }
	if (cmdExists("perf")) { return `perf stat -x, -o ${q(timeFile)} -e instructions:u,task-clock`; }
	return `/usr/bin/time -f "%e %M" -o ${q(timeFile)}`;
}

function timerName(kernel: string): string {
	if (kernel == "Darwin") { return "/usr/bin/time -l (instructions retired, real, max rss)"; }
	if (cmdExists("perf")) { return "perf stat instructions:u + task-clock (ms is cpu time, no rss)"; }
	return "/usr/bin/time -f (real, max rss; no instructions)";
}

function firstNumber(line: string): float64 {
	return line.trim().split(" ")[0].parseFloat();
}

function procRows(kernel: string, timeText: string): string {
	let out = "";
	const lines = timeText.split("\n");
	if (kernel == "Darwin") {
		for (const l of lines) {
			if (l.includes(" real")) { out += `proc\ttotal\tms\t${firstNumber(l) * 1000}\n`; }
			if (l.includes("maximum resident set size")) { out += `proc\ttotal\tbytes\t${firstNumber(l)}\n`; }
			if (l.includes("instructions retired")) { out += `proc\ttotal\tinstr\t${firstNumber(l)}\n`; }
		}
		return out;
	}
	if (cmdExists("perf")) {
		for (const l of lines) {
			const f = l.split(",");
			if (f.length < 3 || l.startsWith("#")) { continue; }
			const v = f[0].parseFloat();
			if (v != v) { continue; }
			if (f[2].startsWith("instructions")) { out += `proc\ttotal\tinstr\t${v}\n`; }
			if (f[2].startsWith("task-clock")) { out += `proc\ttotal\tms\t${v}\n`; }
		}
		return out;
	}
	const f = timeText.trim().split("\n").pop().split(" ");
	if (f.length == 2) { out += `proc\ttotal\tms\t${f[0].parseFloat() * 1000}\nproc\ttotal\tbytes\t${f[1].parseFloat() * 1024}\n`; }
	return out;
}

interface Job {
	program: string;
	arm: string;
	run: int32;
}

function sourceOf(program: string): string {
	if (program == "711") { return "src/test/corpus/programs/711-jsxParseNative.ms"; }
	if (program == "fmt") { return "src/test/fmt/run.ms"; }
	if (program == "self") { return "src/index.ms"; }
	if (program.startsWith("rt:")) { return `src/test/perf/programs/${program.slice(3)}.ms`; }
	fail("unknown program " + program + " (711, fmt, self, rt:<name>)");
	return "";
}

function runJob(kernel: string, job: Job, msc: string, command: string, out: string): void {
	const tag = `${job.program}.${job.arm}.${job.run}`;
	const work = `${out}/work/${tag}`;
	const rows = `${out}/${tag}.tsv`;
	const timeFile = `${work}/time.txt`;
	const log = `${work}/log.txt`;
	absDir(work);
	writeFile(rows, "");
	const envs = `MSC_NO_GLOBAL_CACHE=1 MSC_FLOWS=${q(rows)} MS_DRC_STAT=${q(rows)}`;
	const r = exec(`cd ${q(work)} && ${envs} nice -n 10 ${timerFor(kernel, timeFile)} ${command} > ${q(log)} 2>&1`);
	if (!r.ok) { fail(`run ${tag} failed (${command}); log ${log}`); return; }
	if (readOr(log, "").includes("Up to date")) { fail(`run ${tag} printed "Up to date" and measured nothing; log ${log}`); return; }
	writeFile(rows, readOr(rows, "") + procRows(kernel, readOr(timeFile, "")));
}

function buildRt(kernel: string, program: string, name: string, msc: string, out: string): string {
	const work = `${out}/work/${program}.${name}.build`;
	absDir(work);
	const bin = `${work}/bin`;
	const r = exec(`cd ${q(work)} && MSC_NO_GLOBAL_CACHE=1 nice -n 10 ${q(msc)} build ${q(shellOut("pwd -P") + "/" + sourceOf(program))} --danger --passC=-DMS_DRC_STAT --output=${q(bin)} > ${q(work + "/log.txt")} 2>&1`);
	if (!r.ok) { fail(`build of ${program} with the ${name} compiler failed; log ${work}/log.txt`); }
	return bin;
}

function describe(msc: string): string {
	return `${msc}  ${shellOut(q(msc) + " --version --no-color 2>&1 | head -1")}`;
}

function loadLine(): string {
	return shellOut("uptime | sed 's/.*load averages*: //'");
}

function main(): int32 {
	const runs = envOr("MSPERF_RUNS", "3").parseInt() as int32;
	const programs = envOr("MSPERF_PROGRAMS", "711,fmt").split(",");
	const fixtures = env.get("MSPERF_FIXTURES");
	const kernel = shellOut("uname -s");
	let header = "";
	let out = fixtures;

	if (fixtures != "") {
		header = `fixtures ${fixtures}  runs ${runs}\n`;
	} else {
		const self = env.get("MSPERF_SELF") == "1";
		const baseEnv = env.get("MSPERF_BASE");
		if (baseEnv == "" && !self) { fail("MSPERF_BASE is required (or MSPERF_SELF=1 for a noise check)"); }
		const cand = absPath(envOr("MSPERF_CAND", exists("./msc") ? "./msc" : "msc"));
		const base = self ? cand : absPath(baseEnv);
		out = absDir(envOr("MSPERF_OUT", "out/perf/" + shellOut("date +%Y%m%d-%H%M%S")));
		const loadStart = loadLine();
		const jobs: Job[] = [];
		for (const program of programs) {
			sourceOf(program);
			for (let r = 1; r <= runs; r++) {
				const baseFirst = Math.random() < 0.5;
				jobs.push({ program: program, arm: baseFirst ? "base" : "cand", run: r });
				jobs.push({ program: program, arm: baseFirst ? "cand" : "base", run: r });
			}
		}
		const rtBins = new Map<string, string>();
		for (const program of programs) {
			if (!program.startsWith("rt:")) { continue; }
			rtBins.set(program + "\tbase", buildRt(kernel, program, "base", base, out));
			rtBins.set(program + "\tcand", self ? rtBins.get(program + "\tbase")! : buildRt(kernel, program, "cand", cand, out));
		}
		for (const job of jobs) {
			const msc = job.arm == "base" ? base : cand;
			const command = job.program.startsWith("rt:")
				? q(rtBins.get(job.program + "\t" + job.arm)!)
				: `${q(msc)} build ${q(shellOut("pwd -P") + "/" + sourceOf(job.program))} --emit=c`;
			progress(`  ${job.program} ${job.arm} ${job.run}/${runs}`);
			runJob(kernel, job, msc, command, out);
		}
		header = `base ${describe(base)}\ncand ${describe(cand)}\nhost ${shellOut("uname -srm")}  timer ${timerName(kernel)}\n` +
			`runs ${runs}  load at start ${loadStart}  at end ${loadLine()}\n`;
	}

	let text = header;
	for (const program of programs) { text += "\n" + tableFor(out, program, runs); }
	console.log(text);
	if (fixtures == "") { writeFile(out + "/table.txt", text); }
	return 0;
}

when (!testBuild) {
	exit(main());
}

function fixtureLine(lines: Line[], flow: string): Line {
	for (const l of lines) { if (l.key == flow) { return l; } }
	fail("fixture flow missing: " + flow);
	return lines[0];
}

function fixtureLines(): Line[] {
	const dir = "src/test/perf/fixtures";
	return compare(loadArm(dir, "fx", "base", 3), loadArm(dir, "fx", "cand", 3), 3);
}

test "an exact count equal in every run of both arms is marked =" {
	assert fixtureLine(fixtureLines(), "msc\tpass.steady\tcount").mark == "=";
}

test "an exact count that changed is marked ≠" {
	const l = fixtureLine(fixtureLines(), "msc\tpass.grew\tcount");
	assert l.mark == "≠";
	assert l.delta == 2;
}

test "a timed delta inside noise carries no mark" {
	const l = fixtureLine(fixtureLines(), "msc\tpass.jitter\tinstr");
	assert l.delta == 4000;
	assert l.mark == "";
}

test "a timed delta under 1% carries no mark even when the runs agree exactly" {
	const l = fixtureLine(fixtureLines(), "msc\tfloor.steady\tinstr");
	assert l.noise == 0;
	assert l.mark == "";
}

test "a timed delta beyond three times noise is marked *" {
	const l = fixtureLine(fixtureLines(), "msc\tpass.slower\tinstr");
	assert l.delta == 100000;
	assert l.mark == "*";
}

test "the median of an even sample is the mean of the middle pair" {
	assert median([4.0, 1.0, 3.0, 2.0]) == 2.5;
	assert median([9.0, 1.0, 5.0]) == 5;
}

test "rows rank by instruction delta, then count delta" {
	const r = ranked(fixtureLines());
	assert r[0].key == "proc\ttotal\tinstr";
	assert r[1].key == "msc\tpass.slower\tinstr";
	assert r[2].key == "msc\tpass.jitter\tinstr";
	let firstCount = 0;
	while (tierOf(r[firstCount].metric) != 1) { firstCount += 1; }
	assert r[firstCount].key == "msc\tpass.grew\tcount";
}

test "coverage counts only leaf flows of phase A, and the phases of the msc total" {
	const arm = loadArm("src/test/perf/fixtures", "fx", "base", 3);
	assert coverage(arm) == "leaf flows / phase.A instr 95.0% · phase.* / msc total instr 90.0%";
}
