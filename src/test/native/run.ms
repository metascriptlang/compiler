// Native-execution test runner — MetaScript dogfood (run via `msc run`).
//
//   msc run src/test/native/run.ms
//
// For every case in manifest.ms, builds the program to a native binary under BOTH
// --gc=drc and --gc=orc, runs it under `/usr/bin/time -l`, and asserts: process
// exit == expectExit, peak RSS < maxRssMb (leak guard), and (if set) stdout
// contains expectStdout. The test infra is itself MetaScript, compiled + run
// by msc. It dogfoods std/process (exec).

import { CASES, NativeCase } from "./manifest";
import { exec, exit, env } from "std/process";

const PROG_DIR = "src/test/native/programs/";
const OUT_DIR = "out/native-ms/";
// Build with a HEAD-matched msc — override via `MSC=./msc msc run ...` so the
// suite never depends on a stale installed binary (version skew ≠ regression).
function resolveMsc(): string { const m = env.get("MSC"); return m == "" ? "msc" : m; }
const MSC = resolveMsc();

interface RunOut { exitCode: number; signal: number; output: string; }
interface Cell { pass: boolean; detail: string; }

// Run a shell command, capturing exit code + signal + merged output regardless of
// success/failure (a non-zero exit or crash is data here, not an error to bubble).
function runCapture(cmd: string): RunOut {
	const r = exec(cmd);
	if (r.ok) { return { exitCode: 0, signal: 0, output: r.value }; }
	const e = r.error;
	return { exitCode: e.exitCode, signal: e.signal, output: e.output };
}

// Parse peak RSS (MB) from `/usr/bin/time -l` output. macOS prints bytes on the
// "maximum resident set size" line; the number is the leading token.
function parseRssMB(output: string): number {
	const lines = output.split("\n");
	for (const line of lines) {
		if (line.contains("maximum resident set size")) {
			const idx = line.indexOf("maximum");
			const numStr = line.slice(0, idx).trim();
			const bytes = numStr.parseInt();
			return (bytes as number) / 1048576.0;
		}
	}
	return -1.0;
}

function containsStr(arr: string[], v: string): boolean {
	for (const x of arr) { if (x == v) { return true; } }
	return false;
}

// Build + run one case under one gc mode; return pass + a human detail string.
function evalCell(c: NativeCase, gc: string): Cell {
	const src = PROG_DIR + c.file;
	const bin = OUT_DIR + c.name + "." + gc;

	const b = runCapture(MSC + " build " + src + " --gc=" + gc + " --output=" + bin);
	if (b.exitCode !== 0 && b.signal === 0 && !b.output.contains("Built")) {
		// build produced no binary
		return { pass: false, detail: "build failed" };
	}

	const rr = runCapture("/usr/bin/time -l " + bin + " 2>&1");
	const rssMB = parseRssMB(rr.output);

	const exitOk = rr.signal === 0 && rr.exitCode === c.expectExit;
	const outOk = c.expectStdout == "" || rr.output.contains(c.expectStdout);
	const rssOk = rssMB >= 0.0 && rssMB <= (c.maxRssMb as number);

	let detail = "rss=" + rssMB + "MB exit=" + rr.exitCode;
	if (!exitOk) { detail = detail + " [exit≠" + c.expectExit + " sig=" + rr.signal + "]"; }
	if (!outOk) { detail = detail + " [stdout missing '" + c.expectStdout + "']"; }
	if (!rssOk) { detail = detail + " [RSS>" + c.maxRssMb + "MB]"; }

	return { pass: exitOk && outOk && rssOk, detail };
}

function main(): void {
	const modes: string[] = ["drc", "orc"];
	let fails = 0;
	let xfails = 0;
	let xpasses = 0;

	console.log("");
	console.log("Native execution tier — DRC + ORC (dogfood: msc run)");
	console.log("");

	for (const c of CASES) {
		for (const gc of modes) {
			const isXfail = containsStr(c.xfail, gc);
			const cell = evalCell(c, gc);
			const tag = c.name + " [" + gc + "]";
			if (isXfail) {
				if (cell.pass) { xpasses = xpasses + 1; console.log("  ? XPASS " + tag + " — " + cell.detail); }
				else { xfails = xfails + 1; console.log("  ▷ xfail " + tag); }
			} else {
				if (cell.pass) { console.log("  ✓ " + tag + " — " + cell.detail); }
				else { fails = fails + 1; console.log("  ✗ FAIL " + tag + " — " + cell.detail); }
			}
		}
	}

	console.log("");
	console.log("  " + (CASES.length * 2 - fails - xfails) + " pass · " + fails + " fail · " + xfails + " xfail · " + xpasses + " xpass");
	if (xpasses > 0) { console.log("  NOTE: XPASS = a known-fail now passes — clear its xfail in manifest.ms"); }
	if (fails > 0) { exit(1); }
}
main();
