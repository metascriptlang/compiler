// A diagnostic shows the line as written: the reference reads it from the file
// (msgs.nim `numLines` → `sourceLine`, `lines` drops the CR LF), never from the text it compiles.
// RED MEANS a `.h` import's inlined declarations or a CR reached the rendered line, or its number shifted.

import { execFileResult, cwd, exit, env } from "std/process";
import { ensureDir, isFile, writeFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;

const HEADER_LINE = "import { diagnosticWrittenLineProbe } from \"./probe.h\";";
const DEP_LINE = "import { writtenLineDep } from \"./dep\";";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

if (!isFile(msc)) {
	console.log(`GUARD-FAIL compiler under test not found: ${msc}`);
	exit(1);
}

function checkWithLineEnding(name: string, eol: string): void {
	const dir = `${root}/out/guard/diagnosticWrittenLine/${name}`;
	ensureDir(dir);
	writeFile(`${dir}/probe.h`, `int diagnosticWrittenLineProbe(int x);${eol}`);
	writeFile(`${dir}/dep.ms`, `export const writtenLineDep = 1;${eol}`);
	writeFile(`${dir}/main.ms`, [HEADER_LINE, "", DEP_LINE, "", "console.log(\"unused imports only\");", ""].join(eol));
	const r = execFileResult(msc, ["check", `${dir}/main.ms`]);
	const output = r.output + r.errorOutput;
	if (r.exitCode != 0) report(`[${name}] check exited ${r.exitCode}: ${output}`);
	if (!output.includes(`${HEADER_LINE}\n`)) report(`[${name}] the header import line is not shown as written: ${output}`);
	if (output.includes("@include(")) report(`[${name}] inlined header text reached a diagnostic: ${output}`);
	if (!output.includes("main.ms:3:10")) report(`[${name}] the import after the header is not reported at line 3: ${output}`);
	if (!output.includes(`${DEP_LINE}\n`)) report(`[${name}] the import after the header is not shown as written: ${output}`);
}

checkWithLineEnding("lf", "\n");
checkWithLineEnding("crlf", "\r\n");

if (failed != 0) exit(1);
console.log("GUARD-OK");
