// Standalone driver, not an inline test: the claim is about a runtime built with -DMS_DRC_STAT, which needs a
// child `msc build` and a child run. Siblings: src/test/guard/run.ms (same build-and-run shape).
// Run from the repo root: msc run src/test/perf/drcStatPin.ms   (MSC=<path> names the subject; default ./msc)
// Pin: the same program with N and 2N objects gives exactly the counter deltas the program causes, and a
// ledger-only build of the runtime still compiles and runs.
import { execFileResult, ExecFileResult, exit, env, cwd } from "std/process";
import { readFile, remove, ensureDir, exists } from "std/fs";

const ROOT = cwd();
const OUT = `${ROOT}/out/perf/drcStatPin`;
const MSC = env.get("MSC") != "" ? env.get("MSC") : exists("./msc") ? `${ROOT}/msc` : "msc";
const DEFINE = env.get("DRCSTAT_PIN_PASSC") != "" ? env.get("DRCSTAT_PIN_PASSC") : "-DMS_DRC_STAT";
const SMALL: int64 = 20000;
const BIG: int64 = 40000;

let fails = 0;

function ok(r: ExecFileResult): boolean {
	return r.started && r.pipeOk && r.exitCode == 0 && r.signal == 0;
}

function rows(path: string): Map<string, int64> {
	const out = new Map<string, int64>();
	const text = try readFile(path) catch "";
	for (const line of text.split("\n")) {
		const f = line.split("\t");
		if (f.length == 4 && f[0] == "drc") out.set(`${f[1]}.${f[2]}`, f[3].parseInt());
	}
	return out;
}

function runWith(exe: string, n: int64, stat: string): Map<string, int64> {
	remove(stat);
	env.set("MS_DRC_STAT", stat);
	const r = execFileResult(exe, [`${n}`]);
	if (!ok(r)) {
		console.log(`FAIL ${exe} ${n}: did not exit 0`);
		fails++;
	}
	return rows(stat);
}

function delta(a: Map<string, int64>, b: Map<string, int64>, key: string): int64 {
	return a.has(key) && b.has(key) ? b.get(key)! - a.get(key)! : -1;
}

function expect(program: string, small: Map<string, int64>, big: Map<string, int64>, key: string, want: int64): void {
	const got = delta(small, big, key);
	if (got != want) {
		console.log(`FAIL ${program} ${key}: delta ${got}, want ${want}`);
		fails++;
	} else {
		console.log(`ok   ${program} ${key} +${got}`);
	}
}

ensureDir(OUT);
for (const program of ["collectGraph", "cycleRegister", "closureVisit"]) {
	const exe = `${OUT}/${program}`;
	const b = execFileResult(MSC, ["build", `${ROOT}/src/test/perf/programs/${program}.ms`, `--passC=${DEFINE}`, `--output=${exe}`], OUT);
	if (!ok(b)) {
		console.log(`FAIL build ${program}\n${b.output}${b.errorOutput}`);
		fails++;
		continue;
	}
	const small = runWith(exe, SMALL, `${OUT}/${program}.small`);
	const big = runWith(exe, BIG, `${OUT}/${program}.big`);
	const n = BIG - SMALL;
	if (program == "closureVisit") {
		expect(program, small, big, "alloc.count", n);
		expect(program, small, big, "cycle.register.count", 0);
		continue;
	}
	expect(program, small, big, "alloc.count", 2 * n);
	if (program == "collectGraph") {
		expect(program, small, big, "cycle.register.count", 2 * n);
		expect(program, small, big, "collect.freed.count", 2 * n);
	} else {
		expect(program, small, big, "cycle.register.count", n);
		expect(program, small, big, "collect.freed.count", 0);
	}
}
for (const program of ["collectGraph", "cycleRegister"]) {
	const exe = `${OUT}/${program}.ledger`;
	const b = execFileResult(MSC, ["build", `${ROOT}/src/test/perf/programs/${program}.ms`, "--passC=-DMS_DRC_LEDGER", `--output=${exe}`], OUT);
	const r = ok(b) ? execFileResult(exe, [`${SMALL}`]) : b;
	if (!ok(r)) {
		console.log(`FAIL ledger build ${program}\n${r.output}${r.errorOutput}`);
		fails++;
	} else {
		console.log(`ok   ${program} ledger build runs without the counters`);
	}
}
exit(fails > 0 ? 1 : 0);
