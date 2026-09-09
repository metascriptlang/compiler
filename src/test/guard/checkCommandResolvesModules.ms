// nim-guard: `msc check` must resolve modules through the SAME path as
// `msc build`. A command that type-checks one file in isolation reports every
// import of a healthy multi-file program as an error — a cheap gate that is
// wrong on every real program is worse than no gate.
//
// INVARIANT: check and build share one module-resolution driver.
//   Reference: main.nim routes every command that type-checks through
//   `compileProject` — the module graph is built before semantic analysis, and
//   `check` is a stop-after-sem variant of the same run, never a second driver.
// NIM-REF: §"Command routing" — DIVERGE-UNINTENTIONAL -> SAME. `cmdCheck`
//   called `checkProgram` on a lone parse result with no ModuleGraph, so
//   collectImport took the unresolved-source branch for every import.
//
// WHY A SUBPROCESS: the observable is the CLI command's verdict, which the
//   in-process checker cannot express about itself. The compiler under test is
//   $MSC when the runner exports one, else `./msc` beside the recompiler root.
//
// RED PRE-FIX: check on a two-file program exits 1 with
//   "Cannot resolve module './checkImportDep' to import 'checkImportHelper'".
// GREEN POST-FIX: exit 0, and the two failure modes carry distinct messages.

import { execFile, execFileCapture, cwd, exit, env } from "std/process";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const fixtures = `${root}/src/test/guard/fixtures`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function checkOutput(fixture: string): string {
	const r = execFileCapture(msc, ["check", `${fixtures}/${fixture}`]);
	if (r.ok) return r.value;
	return r.error.output + r.error.errorOutput;
}

const rc = execFile(msc, ["check", `${fixtures}/checkImportMain.ms`]);
if (rc != 0) report(`check rejected a resolvable relative import (exit ${rc})`);

const unresolved = checkOutput("checkImportMissingModule.ms");
if (!unresolved.includes("Cannot resolve module './noSuchModule'")) {
	report(`unresolved module lacks its own message: ${unresolved}`);
}
if (unresolved.includes("to import")) {
	report(`unresolved module blamed a symbol: ${unresolved}`);
}

const missing = checkOutput("checkImportMissingExport.ms");
if (!missing.includes("Module './checkImportDep' has no export 'missingSymbol'")) {
	report(`missing export lacks its own message: ${missing}`);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
