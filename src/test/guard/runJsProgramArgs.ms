// `msc run <file> --target=js [args]` hands the program `argv = [script, ...args]`, the
// same shape the native backend gives (`[binary, ...args]`), and a module that imports an
// `extern const` bound by an `@import` in another module reaches that binding.
//
// WHY A SUBPROCESS: the observable is the emitted per-module tree run by node, which no
// in-process test reaches. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: `ReferenceError: argv is not defined` (the tree imported the module for its
// side effect only), and once bound, `argv` was `[node, script, ...args]`.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardRunJsProgramArgs`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/host.ms`, "@import(\"node:os\", { EOL });\nexport extern const EOL: string;\n");
writeFile(`${dir}/echo.ms`, [
	"import { argv, cwd, exit } from \"std/process\";",
	"import { EOL } from \"./host\";",
	"console.log(\"argc=\" + argv.length);",
	"for (let i = 1; i < argv.length; i += 1) { console.log(\"arg=\" + argv[i]); }",
	"console.log(\"script=\" + argv[0].endsWith(\"echo.js\"));",
	"console.log(\"cwd=\" + (cwd().length > 0));",
	"console.log(\"eol=\" + EOL.length);",
	"exit(3);",
	"",
].join("\n"));

const r = execFileResult(msc, ["run", "echo.ms", "--target=js", "a", "b c"], dir);
const out = r.output;
const all = `${out}${r.errorOutput}`;
if (r.exitCode != 3) report(`exit code ${r.exitCode}, want 3 from std/process exit: ${all}`);
if (!out.includes("argc=3\n")) report(`argc, want [script, a, b c]: ${all}`);
if (!out.includes("arg=a\narg=b c\n")) report(`args after the script: ${all}`);
if (!out.includes("script=true\n")) report(`argv[0] is not the emitted script: ${all}`);
if (!out.includes("cwd=true\n")) report(`cwd from std/process: ${all}`);
if (!out.includes("eol=1\n")) report(`extern const from a sibling module: ${all}`);

if (failed != 0) exit(1);
console.log("GUARD-OK");
