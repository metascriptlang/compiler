// wasmmix oracle: each programs/<name>/main.ms runs all-C, all-JS, mixed and
// tree (the `@wasm` functions placed in wasm); the stdouts must be byte-equal
// and equal the `// @stdout:` lines.
//
//   // @stdout: <line>        -> one expected stdout line; repeated in order
//   // @mixed-error: <substr> -> the mixed build must fail with <substr>
//   // @error: <substr>       -> every column's build must fail with <substr>
//                                (c, js, mixed and tree); no column runs
//   // @foreign-stdout: <line> -> a line printed by foreign.mjs
//   // @slots                 -> slotTable.mjs checks the built slot table
//   // @columns: <list>       -> only these of c, js, mixed run (default all);
//                                tree runs with mixed
//   // @mixed-stderr: <substr> -> the mixed run's stderr has a line with it; a
//                                program without it fails on a `msb leak:` line
//   // @loads: <n>            -> n loads of the module (not available yet)
//   // @ledger-balanced: <T>  -> the wasm half's DRC ledger row of T (of an
//                                instance of generic T: its last row) has
//                                alloc == destroy (mixed build with the ledger)
//   // @ledger-leaks: <T>     -> the same row has alloc != destroy; pins that
//                                the oracle bites
//
//   MSC=./msc msc run src/test/wasmmix/run.ms
//   WASMMIX_ONLY=scalars,callback  # select programs
//
// Columns: c = `msc run`; js = `build --target=js --wasm-placement=off` then
// node; mixed = `build --target=js` then node, and the build must write
// <stem>.wasm.mjs and <stem>.wasm beside the bundle, so a compiler that
// ignores `@wasm` is red; tree = `run --target=js` (the ES module tree), which
// places the same way and refuses the same programs.
// The emcc environment (PATH, VOID_EMSDK_*, EM_CONFIG) is inherited.

import { execFileResult, exit, env, platform } from "std/process";
import { readFile, readDir, exists, ensureDir, remove, isDir } from "std/fs";
import { writeStderr } from "std/io";
import {
	parseSpec,
	describeDiff,
	hasLineWith,
	hasLineStartingWith,
	normalizeOutput,
	WasmmixSpec,
} from "./spec";

const PROG_DIR = "src/test/wasmmix/programs/";
const OUT_DIR = "out/wasmmix/";
const RUN_PAGE = "src/test/wasmmix/browser/runPage.mjs";
const SLOTS = "src/test/wasmmix/slotTable.mjs";
const LEDGER_HOOK = "./src/test/wasmmix/ledgerHook.mjs";
const LEDGER_FLAGS = [
	"--passC=-DMS_DRC_LEDGER -DMS_LEDGER_SET_SIZE=65536u",
];
const BROWSER = env.get("WASMMIX_BROWSER") == "1";
const TAIL_LINES: int32 = 12;

function resolveMsc(): string {
	const explicit = env.get("MSC");
	if (explicit != "") return explicit;
	if (platform == "windows" && exists("./msc.exe")) return "./msc.exe";
	if (exists("./msc")) return "./msc";
	return "msc";
}

const MSC = resolveMsc();

function say(line: string): void {
	writeStderr(line + "\n");
}

interface Column {
	name: string;
	ok: boolean;
	out: string;
	err: string;
	detail: string;
}

function failedColumn(name: string, detail: string, out: string = ""): Column {
	return { name, ok: false, out, err: "", detail };
}

function tail(text: string): string {
	const lines = text.trim().split("\n");
	const from = lines.length > TAIL_LINES ? lines.length - TAIL_LINES : 0;
	return lines.slice(from, lines.length).join("\n");
}

function runProcess(label: string, path: string, args: string[]): Column {
	const r = execFileResult(path, args);
	if (!r.started) return failedColumn(label, `could not start ${path}`);
	if (r.exitCode != 0 || r.signal != 0) {
		const detail = `exit ${r.exitCode} signal ${r.signal}`;
		return failedColumn(
			label,
			`${detail}\n${tail(r.errorOutput + r.output)}`,
			r.output,
		);
	}
	return { name: label, ok: true, out: r.output, err: r.errorOutput, detail: "" };
}

function buildAndRun(
	label: string,
	entry: string,
	dir: string,
	flags: string[],
	wantWasm: boolean,
	ledger: boolean = false,
): Column {
	ensureDir(dir);
	const bundle = dir + "app.js";
	const stem = dir + "app";
	const wasmArtifacts = [stem + ".wasm.mjs", stem + ".wasm"];
	for (const f of [bundle, ...wasmArtifacts]) {
		if (exists(f)) remove(f);
	}
	const args = ["build", entry, "--target=js", ...flags, "--output=" + bundle];
	const build = runProcess(label + " build", MSC, args);
	if (!build.ok) return build;
	if (wantWasm) {
		for (const artifact of wasmArtifacts) {
			if (exists(artifact)) continue;
			return failedColumn(
				label,
				`no .wasm artifact: build succeeded but ${artifact} was not written (@wasm ignored?)`,
			);
		}
	}
	if (ledger) return runProcess(label, "node", ["--import", LEDGER_HOOK, bundle]);
	return runProcess(label, "node", [bundle]);
}

function ledgerRow(err: string, type: string): string {
	let row = "";
	for (const line of err.split("\n")) {
		const own = line.startsWith(`LEDGER ${type} `);
		if (own || line.startsWith(`LEDGER ${type}_`)) row = line;
	}
	return row;
}

function ledgerCount(row: string, key: string): string {
	for (const word of row.split(" ")) {
		if (word.startsWith(key + "=")) return word.slice(key.length + 1, word.length);
	}
	return "";
}

function ledgerProblems(spec: WasmmixSpec, mixed: Column): string[] {
	if (!mixed.ok) return [];
	const problems: string[] = [];
	const wants: string[][] = [
		...spec.ledgerBalanced.map((t) => [t, "balanced"]),
		...spec.ledgerLeaks.map((t) => [t, "leaks"]),
	];
	for (const want of wants) {
		const row = ledgerRow(mixed.err, want[0]);
		if (row == "") {
			problems.push(`[mixed] no LEDGER row for ${want[0]}:\n${tail(mixed.err)}`);
			continue;
		}
		const alloc = ledgerCount(row, "alloc");
		const balanced = alloc == ledgerCount(row, "destroy");
		if (balanced == (want[1] == "balanced")) continue;
		const verdict = want[1] == "balanced" ? "imbalance" : "no imbalance";
		problems.push(`[mixed] ledger ${verdict} for ${want[0]}: ${row}`);
	}
	return problems;
}

function judge(spec: WasmmixSpec, cols: Column[]): string[] {
	const problems: string[] = [];
	if (cols.length == 0) return problems;
	const expected = spec.hasStdout ? spec.stdout.join("\n") + "\n" : "";
	for (const c of cols) {
		if (!c.ok) {
			problems.push(`[${c.name}] ${c.detail}`);
			continue;
		}
		if (!spec.hasStdout) continue;
		const diff = describeDiff(expected, c.out);
		if (diff != "") problems.push(`[${c.name}] differs from @stdout: ${diff}`);
	}
	const base = cols[0];
	for (let i = 1; i < cols.length; i += 1) {
		if (!base.ok || !cols[i].ok) continue;
		const diff = describeDiff(base.out, cols[i].out);
		if (diff == "") continue;
		problems.push(`[${cols[i].name}] differs from [${base.name}]: ${diff}`);
	}
	return problems;
}

function stderrProblems(spec: WasmmixSpec, mixed: Column): string[] {
	if (!mixed.ok) return [];
	const problems: string[] = [];
	for (const want of spec.mixedStderr) {
		if (hasLineWith(mixed.err, want)) continue;
		const missing = `[mixed] stderr lacks ${JSON.stringify(want)}`;
		problems.push(`${missing}:\n${tail(mixed.err)}`);
	}
	if (spec.mixedStderr.length == 0 && hasLineStartingWith(mixed.err, "msb leak:")) {
		problems.push(`[mixed] unexpected leak report:\n${tail(mixed.err)}`);
	}
	return problems;
}

function readText(path: string): string {
	const r = readFile(path);
	return r.ok ? normalizeOutput(r.value) : "";
}

function refusalProblems(
	wants: string[],
	column: string,
	args: string[],
): string[] {
	const problems: string[] = [];
	const r = execFileResult(MSC, args);
	const text = r.output + r.errorOutput;
	if (r.exitCode == 0) {
		const want = JSON.stringify(wants[0]);
		problems.push(
			`[${column}] succeeded, expected an error containing ${want}`,
		);
		return problems;
	}
	for (const want of wants) {
		if (hasLineWith(text, want)) continue;
		const missing = `[${column}] error lacks ${JSON.stringify(want)}`;
		problems.push(`${missing}:\n${tail(text)}`);
	}
	return problems;
}

function expectedErrorProblems(
	spec: WasmmixSpec,
	dir: string,
	entry: string,
): string[] {
	ensureDir(dir + "mixed/");
	const bundle = dir + "mixed/app.js";
	const mixedArgs = ["build", entry, "--target=js", "--output=" + bundle];
	return refusalProblems(spec.mixedErrors, "mixed", mixedArgs).concat(
		refusalProblems(spec.mixedErrors, "tree", ["run", "--target=js", entry]),
	);
}

function everyColumnErrorProblems(
	spec: WasmmixSpec,
	dir: string,
	entry: string,
): string[] {
	ensureDir(dir + "js/");
	ensureDir(dir + "mixed/");
	const js = ["build", entry, "--target=js", "--wasm-placement=off", "--output=" + dir + "js/app.js"];
	const mixed = ["build", entry, "--target=js", "--output=" + dir + "mixed/app.js"];
	return refusalProblems(spec.errors, "c", ["build", entry, "--output=" + dir + "c/app"])
		.concat(refusalProblems(spec.errors, "js", js))
		.concat(refusalProblems(spec.errors, "mixed", mixed))
		.concat(refusalProblems(spec.errors, "tree", ["run", "--target=js", entry]));
}

function foreignProblems(
	spec: WasmmixSpec,
	driver: string,
	bundle: string,
): string[] {
	const foreign = runProcess("foreign", "node", [driver, bundle]);
	if (!foreign.ok) return [`[foreign] ${foreign.detail}`];
	const expected = spec.stdout.concat(spec.foreignStdout).join("\n") + "\n";
	const diff = describeDiff(expected, foreign.out);
	if (diff == "") return [];
	return [`[foreign] differs from @stdout then @foreign-stdout: ${diff}`];
}

function runProgram(name: string): boolean {
	const entry = PROG_DIR + name + "/main.ms";
	const spec = parseSpec(readText(entry));
	if (spec.unknown.length > 0) {
		say(`  FAIL ${name} — unknown directive ${spec.unknown[0]}`);
		return false;
	}
	const problems: string[] = [];
	if (spec.loads != 1) {
		problems.push(`@loads: ${spec.loads} is not available yet`);
	}
	if (problems.length > 0) {
		say(`  FAIL ${name}`);
		for (const p of problems) say("    " + p);
		return false;
	}
	const dir = OUT_DIR + name + "/";
	if (spec.errors.length > 0) {
		const others = spec.hasStdout || spec.mixedErrors.length > 0 || spec.foreignStdout.length > 0
			|| spec.mixedStderr.length > 0 || spec.slots
			|| spec.ledgerBalanced.length + spec.ledgerLeaks.length > 0;
		if (others) problems.push("@error builds no column, so it stands alone in the head");
		for (const p of everyColumnErrorProblems(spec, dir, entry)) problems.push(p);
		return report(name, problems);
	}
	const cols: Column[] = [];
	if (spec.columns.includes("c")) {
		cols.push(runProcess("c", MSC, ["run", entry]));
	}
	if (spec.columns.includes("js")) {
		cols.push(
			buildAndRun("js", entry, dir + "js/", ["--wasm-placement=off"], false),
		);
	}
	const driver = PROG_DIR + name + "/foreign.mjs";
	const wantsForeign = spec.foreignStdout.length > 0;
	if (wantsForeign != exists(driver)) {
		problems.push(`@foreign-stdout lines and ${driver} must come together`);
	}
	if (spec.mixedErrors.length > 0) {
		if (spec.mixedStderr.length > 0) {
			problems.push("@mixed-stderr needs a mixed run and @mixed-error expects it to fail");
		}
		if (wantsForeign) {
			problems.push(
				"@foreign-stdout needs a mixed build and @mixed-error expects it to fail",
			);
		}
		for (const p of expectedErrorProblems(spec, dir, entry)) problems.push(p);
	} else {
		const ledger = spec.ledgerBalanced.length + spec.ledgerLeaks.length > 0;
		const mixed = buildAndRun(
			"mixed",
			entry,
			dir + "mixed/",
			ledger ? LEDGER_FLAGS : [],
			true,
			ledger,
		);
		cols.push(mixed);
		cols.push(runProcess("tree", MSC, ["run", "--target=js", entry]));
		for (const p of stderrProblems(spec, mixed)) problems.push(p);
		for (const p of ledgerProblems(spec, mixed)) problems.push(p);
		const bundle = dir + "mixed/app.js";
		if (mixed.ok && wantsForeign && exists(driver)) {
			for (const p of foreignProblems(spec, driver, bundle)) problems.push(p);
		}
		if (spec.slots && mixed.ok) {
			const slots = runProcess("slots", "node", [
				SLOTS,
				dir + "mixed/",
				"app.js",
			]);
			if (!slots.ok) problems.push(`[slots] ${slots.detail}`);
		}
		if (BROWSER && mixed.ok) {
			cols.push(
				runProcess("browser", "node", [RUN_PAGE, dir + "mixed/", "app.js"]),
			);
		}
	}
	for (const p of judge(spec, cols)) problems.push(p);
	return report(name, problems);
}

function report(name: string, problems: string[]): boolean {
	if (problems.length == 0) {
		say(`  PASS ${name}`);
		return true;
	}
	say(`  FAIL ${name}`);
	for (const p of problems) say("    " + p.replaceAll("\n", "\n      "));
	return false;
}

function selectedPrograms(): string[] {
	const only = env.get("WASMMIX_ONLY");
	const wanted = only == "" ? [] : only.split(",");
	const names: string[] = [];
	for (const e of readDir(PROG_DIR)) {
		const name = e.endsWith("/") ? e.slice(0, e.length - 1) : e;
		if (!isDir(PROG_DIR + name)) continue;
		if (wanted.length > 0 && !wanted.includes(name)) continue;
		names.push(name);
	}
	return names;
}

say(`wasmmix: compiler ${MSC}`);
const programs = selectedPrograms();
let failed: int32 = 0;
for (const name of programs) {
	if (!runProgram(name)) failed += 1;
}
if (programs.length == 0) {
	say("wasmmix: no program selected");
	exit(2);
}
say(`wasmmix: ${programs.length - failed}/${programs.length} pass`);
if (failed > 0) exit(1);
