// nim-guard: `msc check` must resolve modules through the SAME path as
// `msc build`. A command that type-checks one file in isolation reports every
// import of a healthy multi-file program as an error — a cheap gate that is
// wrong on every real program is worse than no gate.
//
// INVARIANT: check and build share one driver; the command chooses how far the
//   pipeline runs, never whether imports resolve.
//   Reference (read 2026-09-10): `commandCheck` (main.nim:90) installs the sem
//   pass then calls `compilePipelineProject`; `commandCompileToC` (main.nim:148)
//   installs the codegen pass and calls the SAME proc. The check command is
//   declared "semantic checking for whole project" (options.nim:184).
//   Not parity, and not claimed here: the reference resolves imports lazily
//   from inside sem (importPipelineModule, pipelines.nim:499 — "this is called
//   by the semantic checking phase"), while we load an eager module graph first
//   — NIM-REF §1 "Import resolution", DIVERGE-INTENTIONAL. This guard pins the
//   one-driver rule, not the eager/lazy shape.
// VERDICT: was DIVERGE-UNINTENTIONAL -> SAME. `cmdCheck` called `checkProgram`
//   on a lone parse result with no ModuleGraph, so collectImport took the
//   unresolved-source branch for every import.
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
