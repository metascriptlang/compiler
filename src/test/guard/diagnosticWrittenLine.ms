// A diagnostic shows the line as written: the reference reads it from the file
// (msgs.nim `numLines` → `sourceLine`), never from the text it compiles.
// RED MEANS a `.h` import's inlined declarations reached the rendered line or shifted its number.

import { execFileResult, cwd, exit, env } from "std/process";
import { isFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const main = `${root}/src/test/guard/fixtures/diagnosticWrittenLine/main.ms`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

for (const path of [msc, main]) {
	if (!isFile(path)) {
		console.log(`GUARD-FAIL not found: ${path} (run from the recompiler root)`);
		exit(1);
	}
}

const r = execFileResult(msc, ["check", main]);
const output = r.output + r.errorOutput;
if (r.exitCode != 0) report(`check exited ${r.exitCode}: ${output}`);

if (!output.includes("import { diagnosticWrittenLineProbe } from \"./probe.h\";\n")) {
	report(`the header import line is not shown as written: ${output}`);
}
if (output.includes("@include(")) report(`inlined header text reached a diagnostic: ${output}`);
if (!output.includes("main.ms:3:10")) report(`the import after the header is not reported at line 3: ${output}`);
if (!output.includes("import { writtenLineDep } from \"./dep\";\n")) {
	report(`the import after the header is not shown as written: ${output}`);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
