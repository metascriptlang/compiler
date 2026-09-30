// `msc run <file> [args]` hands the program its arguments: a positional after the
// file, everything after `--` verbatim, and an unknown flag is an error that names `--`.
// On Raiser argv[0] is the file as given, and output streams in order with a child's.
//
// WHY A SUBPROCESS: the observable is the built program's own argv, which the option
// parser's unit tests cannot reach. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: the program saw only its own path; `a` and `b c` were dropped. On Raiser
// argv was msc's own command line, and console.log printed after the child's output.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardRunProgramArgs`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/echo.ms`, "import { argv } from \"std/process\";\nfor (let i = 1; i < argv.length; i += 1) { console.log(\"arg=\" + argv[i]); }\n");
writeFile(`${dir}/echo0.ms`, "import { argv } from \"std/process\";\nfor (const a of argv) { console.log(\"arg=\" + a); }\n");
writeFile(`${dir}/order.ms`, `import { execFile } from "std/process";\nconsole.log("line=A");\nexecFile("${msc}", ["run", "echo.ms", "--target=raiser", "child"]);\nconsole.log("line=C");\n`);

function runEcho(args: string[]): string {
	const all: string[] = ["run", "echo.ms"];
	for (const a of args) { all.push(a); }
	const r = execFileResult(msc, all, dir);
	if (r.exitCode != 0) return `exit ${r.exitCode}: ${r.output}${r.errorOutput}`;
	return r.output;
}

function lines(out: string): string {
	let kept = "";
	for (const l of out.split("\n")) {
		if (l.startsWith("arg=")) kept = kept + l + "|";
	}
	return kept;
}

const positional = lines(runEcho(["a", "b c"]));
if (positional != "arg=a|arg=b c|") report(`positionals after the file: ${positional}`);

const dashed = lines(runEcho(["--", "--foo", "--release", "--", "x"]));
if (dashed != "arg=--foo|arg=--release|arg=--|arg=x|") report(`after --: ${dashed}`);

const known = lines(runEcho(["--release", "a"]));
if (known != "arg=a|") report(`a known msc flag after the file: ${known}`);

const unknown = runEcho(["--foo"]);
if (!unknown.includes("exit 1") || !unknown.includes("msc run <file> -- --foo")) {
	report(`unknown flag after the file: ${unknown}`);
}

function runRaiser(file: string, args: string[]): string {
	const all: string[] = ["run", file, "--target=raiser"];
	for (const a of args) { all.push(a); }
	const r = execFileResult(msc, all, dir);
	if (r.exitCode != 0) return `exit ${r.exitCode}: ${r.output}${r.errorOutput}`;
	return r.output;
}

function tagged(out: string): string {
	let kept = "";
	for (const l of out.split("\n")) {
		if (l.startsWith("arg=") || l.startsWith("line=")) kept = kept + l + "|";
	}
	return kept;
}

const raiserArgv = tagged(runRaiser("echo0.ms", ["a", "b c"]));
if (raiserArgv != "arg=echo0.ms|arg=a|arg=b c|") report(`raiser argv: ${raiserArgv}`);

const order = tagged(runRaiser("order.ms", []));
if (order != "line=A|arg=child|line=C|") report(`raiser output order around a child: ${order}`);

if (failed != 0) exit(1);
console.log("GUARD-OK");
