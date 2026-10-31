// wasmmix oracle (M1): each programs/<name>/main.ms runs all-C, all-JS and mixed
// (the `@wasm` functions placed in wasm); the three stdouts must be byte-equal
// and equal the `// @stdout:` lines.
//
//   // @stdout: <line>        -> one expected stdout line; repeated in order
//   // @mixed-error: <substr> -> the mixed build must fail with <substr> in its output
//
//   MSC=./msc msc run src/test/wasmmix/run.ms
//   WASMMIX_ONLY=scalars,callback  # select programs
//
// Columns: c = `msc run`; js = `build --target=js --wasm-placement=off` then node;
// mixed = `build --target=js` then node, and the build must write <stem>.wasm.mjs
// and <stem>.wasm beside the bundle, so a compiler that ignores `@wasm` is red.
// The emcc environment (PATH, VOID_EMSDK_*, EM_CONFIG) is inherited.

import { execFileResult, exit, env, platform } from "std/process";
import { readFile, readDir, exists, ensureDir, remove, isDir } from "std/fs";
import { writeStderr } from "std/io";
import { parseSpec, describeDiff, normalizeOutput, WasmmixSpec } from "./spec";

const PROG_DIR = "src/test/wasmmix/programs/";
const OUT_DIR = "out/wasmmix/";

function resolveMsc(): string {
	const explicit = env.get("MSC");
	if (explicit != "") { return explicit; }
	if (platform == "windows" && exists("./msc.exe")) { return "./msc.exe"; }
	if (exists("./msc")) { return "./msc"; }
	return "msc";
}
const MSC = resolveMsc();
const BROWSER = env.get("WASMMIX_BROWSER") == "1";
const RUN_PAGE = "src/test/wasmmix/browser/runPage.mjs";
const SLOTS = "src/test/wasmmix/slotTable.mjs";

function say(line: string): void {
	writeStderr(line + "\n");
}

interface Column {
	name: string;
	ok: boolean;
	out: string;
	detail: string;
}

function tail(s: string): string {
	const lines = s.trim().split("\n");
	const from = lines.length > 12 ? lines.length - 12 : 0;
	return lines.slice(from, lines.length).join("\n");
}

function runProcess(label: string, path: string, args: string[]): Column {
	const r = execFileResult(path, args);
	if (!r.started) { return { name: label, ok: false, out: "", detail: `could not start ${path}` }; }
	if (r.exitCode != 0 || r.signal != 0) {
		return { name: label, ok: false, out: r.output, detail: `exit ${r.exitCode} signal ${r.signal}\n${tail(r.errorOutput + r.output)}` };
	}
	return { name: label, ok: true, out: r.output, detail: "" };
}

function buildAndRun(label: string, entry: string, dir: string, flags: string[], wantWasm: boolean): Column {
	ensureDir(dir);
	const bundle = dir + "app.js";
	const stem = dir + "app";
	for (const f of [bundle, stem + ".wasm.mjs", stem + ".wasm"]) { if (exists(f)) { remove(f); } }
	const build = runProcess(label + " build", MSC, ["build", entry, "--target=js", ...flags, "--output=" + bundle]);
	if (!build.ok) { return build; }
	if (wantWasm) {
		for (const art of [stem + ".wasm.mjs", stem + ".wasm"]) {
			if (!exists(art)) { return { name: label, ok: false, out: "", detail: `no .wasm artifact: build succeeded but ${art} was not written (@wasm ignored?)` }; }
		}
	}
	return runProcess(label, "node", [bundle]);
}

function judge(spec: WasmmixSpec, cols: Column[]): string[] {
	const problems: string[] = [];
	const expected = spec.hasStdout ? spec.stdout.join("\n") + "\n" : "";
	for (const c of cols) {
		if (!c.ok) { problems.push(`[${c.name}] ${c.detail}`); continue; }
		if (spec.hasStdout) {
			const d = describeDiff(expected, c.out);
			if (d != "") { problems.push(`[${c.name}] differs from @stdout: ${d}`); }
		}
	}
	const base = cols[0];
	for (let i = 1; i < cols.length; i = i + 1) {
		if (!base.ok || !cols[i].ok) { continue; }
		const d = describeDiff(base.out, cols[i].out);
		if (d != "") { problems.push(`[${cols[i].name}] differs from [${base.name}]: ${d}`); }
	}
	return problems;
}

function readText(path: string): string {
	const r = readFile(path);
	return r.ok ? normalizeOutput(r.value) : "";
}

function runProgram(name: string): boolean {
	const entry = PROG_DIR + name + "/main.ms";
	const spec = parseSpec(readText(entry));
	if (spec.unknown.length > 0) { say(`  FAIL ${name} — unknown directive ${spec.unknown[0]}`); return false; }
	const dir = OUT_DIR + name + "/";
	const cols: Column[] = [];
	cols.push(runProcess("c", MSC, ["run", entry]));
	cols.push(buildAndRun("js", entry, dir + "js/", ["--wasm-placement=off"], false));
	const problems: string[] = [];
	const driver = PROG_DIR + name + "/foreign.mjs";
	const wantsForeign = spec.foreignStdout.length > 0;
	if (wantsForeign != exists(driver)) { problems.push(`@foreign-stdout lines and ${driver} must come together`); }
	if (spec.mixedError != "") {
		if (wantsForeign) { problems.push("@foreign-stdout needs a mixed build and @mixed-error expects it to fail"); }
		ensureDir(dir + "mixed/");
		const b = execFileResult(MSC, ["build", entry, "--target=js", "--output=" + dir + "mixed/app.js"]);
		const text = b.output + b.errorOutput;
		if (b.exitCode == 0) { problems.push(`[mixed] build succeeded, expected an error containing ${JSON.stringify(spec.mixedError)}`); }
		else if (!text.contains(spec.mixedError)) { problems.push(`[mixed] error lacks ${JSON.stringify(spec.mixedError)}:\n${tail(text)}`); }
	} else {
		const mixed = buildAndRun("mixed", entry, dir + "mixed/", [], true);
		cols.push(mixed);
		if (mixed.ok && wantsForeign && exists(driver)) {
			const foreign = runProcess("foreign", "node", [driver, dir + "mixed/app.js"]);
			if (!foreign.ok) {
				problems.push(`[foreign] ${foreign.detail}`);
			} else {
				const d = describeDiff(spec.stdout.concat(spec.foreignStdout).join("\n") + "\n", foreign.out);
				if (d != "") { problems.push(`[foreign] differs from @stdout then @foreign-stdout: ${d}`); }
			}
		}
		if (spec.slots && mixed.ok) {
			const slots = runProcess("slots", "node", [SLOTS, dir + "mixed/", "app.js"]);
			if (!slots.ok) { problems.push(`[slots] ${slots.detail}`); }
		}
		if (BROWSER && mixed.ok) { cols.push(runProcess("browser", "node", [RUN_PAGE, dir + "mixed/", "app.js"])); }
	}
	for (const p of judge(spec, cols)) { problems.push(p); }
	if (problems.length == 0) { say(`  PASS ${name}`); return true; }
	say(`  FAIL ${name}`);
	for (const p of problems) { say("    " + p.replaceAll("\n", "\n      ")); }
	return false;
}

const only = env.get("WASMMIX_ONLY");
const wanted = only == "" ? [] : only.split(",");
say(`wasmmix: compiler ${MSC}`);
let failed = 0;
let ran = 0;
for (const e of readDir(PROG_DIR)) {
	const name = e.endsWith("/") ? e.slice(0, e.length - 1) : e;
	if (!isDir(PROG_DIR + name)) { continue; }
	if (wanted.length > 0 && !wanted.includes(name)) { continue; }
	ran = ran + 1;
	if (!runProgram(name)) { failed = failed + 1; }
}
if (ran == 0) { say("wasmmix: no program selected"); exit(2); }
say(`wasmmix: ${ran - failed}/${ran} pass`);
if (failed > 0) { exit(1); }
