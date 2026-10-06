// `console.warn` and `console.error` accept any number of values like `console.log`, join them
// with spaces and write the line to stderr on C, JS and Raiser; stdout keeps only `console.log`.
// The JS output calls `console.warn` and `console.error` themselves, so a browser keeps the level.
//
// WHY A SUBPROCESS: the observable is which stream a built program writes, which no in-process
// test can see. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: C stopped at `Property 'warn' does not exist on type 'console'`; JS refused more
// than one value; Raiser had no host bridge. GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, readFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardConsoleWarnStderr`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function programLines(text: string): string {
	let kept = "";
	for (const l of text.split("\n")) {
		if (l != "" && !l.startsWith("Built ") && !l.contains("Built ")) kept = kept + l + "|";
	}
	return kept;
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/warn.ms`, [
	"const index = 7;",
	"const count = 3;",
	"console.log(\"before\");",
	"console.warn(\"clamp warning\");",
	"console.warn(`initialScrollIndex ${index} is out of range for ${count} items`, index, count);",
	"console.error(\"error line\", index, true);",
	"console.log(\"after\");",
	"",
].join("\n"));

const wantStdout = "before|after|";
const wantStderr = "clamp warning|initialScrollIndex 7 is out of range for 3 items 7 3|error line 7 true|";
for (const target of ["c", "js", "raiser"]) {
	const r = execFileResult(msc, ["run", `--target=${target}`, "warn.ms"], dir);
	if (r.exitCode != 0) {
		report(`${target}: exit ${r.exitCode}: ${r.output}${r.errorOutput}`);
		continue;
	}
	const out = programLines(r.output);
	const err = programLines(r.errorOutput);
	if (out != wantStdout) report(`${target}: stdout ${out}, want ${wantStdout}`);
	if (err != wantStderr) report(`${target}: stderr ${err}, want ${wantStderr}`);
}

const built = execFileResult(msc, ["build", "--target=js", "warn.ms", "--output=warn.js"], dir);
const js = readFile(`${dir}/warn.js`);
if (built.exitCode != 0 || !js.ok) {
	report(`js build: exit ${built.exitCode}: ${built.errorOutput}`);
} else {
	if (!js.value.contains("console.warn(\"clamp warning\")")) report("the JS output does not call console.warn");
	if (!js.value.contains("console.error(")) report("the JS output does not call console.error");
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
