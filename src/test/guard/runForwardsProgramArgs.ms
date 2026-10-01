// `msc run [options] <file> [args]` hands the program everything after the file, flags and
// `--` included; an msc option right after the file is an error that says to move it.
// On Raiser argv[0] is the file as given, and output streams in order with a child's.
// `msc x <cmd>` runs a declared command on Raiser: argv[0] is the command name and its
// exit status is msc's.
//
// WHY A SUBPROCESS: the observable is the built program's own argv, which the option
// parser's unit tests cannot reach. The compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: the program saw only its own path; `a` and `b c` were dropped. On Raiser
// argv was msc's own command line, and console.log printed after the child's output.
// `msc x` built the command to C and gave it the cached binary's path as argv[0].
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
writeFile(`${dir}/order.ms`, `import { execFile } from "std/process";\nconsole.log("line=A");\nexecFile("${msc}", ["run", "--target=raiser", "echo.ms", "child"]);\nconsole.log("line=C");\n`);

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

const passed = lines(runEcho(["a", "--release", "--", "--foo"]));
if (passed != "arg=a|arg=--release|arg=--|arg=--foo|") report(`flags and -- after a program argument: ${passed}`);

const unknownFirst = lines(runEcho(["--foo", "x"]));
if (unknownFirst != "arg=--foo|arg=x|") report(`a flag msc does not know right after the file: ${unknownFirst}`);

const misplaced = runEcho(["--release", "a"]);
if (!misplaced.includes("exit 1") || !misplaced.includes("put it before the file: msc run --release echo.ms")) {
	report(`an msc option right after the file: ${misplaced}`);
}

function runRaiser(file: string, args: string[]): string {
	const all: string[] = ["run", "--target=raiser", file];
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

ensureDir(`${dir}/pkg/tool`);
ensureDir(`${dir}/app`);
writeFile(`${dir}/pkg/build.ms`, "const config = { package: { name: \"greeter\", version: \"1.0.0\", bin: { \"greet\": \"tool/greet.ms\", \"fail3\": \"tool/fail3.ms\" } } };\nexport default config;\n");
writeFile(`${dir}/pkg/tool/greet.ms`, "import { argv } from \"std/process\";\nfor (const a of argv) { console.log(\"arg=\" + a); }\n");
writeFile(`${dir}/pkg/tool/fail3.ms`, "import { exit } from \"std/process\";\nexit(3);\n");
writeFile(`${dir}/app/build.ms`, "const config = { package: { name: \"app\", version: \"1.0.0\" }, deps: { \"greeter\": \"file:../pkg\" } };\nexport default config;\n");

const xGreet = execFileResult(msc, ["x", "greet", "a", "b c"], `${dir}/app`);
const xArgs = tagged(xGreet.output);
if (xGreet.exitCode != 0 || xArgs != "arg=greet|arg=a|arg=b c|") report(`msc x argv: exit ${xGreet.exitCode} ${xArgs}`);
if (xGreet.output.includes("Built ")) report(`msc x printed a build line: ${xGreet.output}`);

const xFail = execFileResult(msc, ["x", "fail3"], `${dir}/app`);
if (xFail.exitCode != 3) report(`msc x exit status: ${xFail.exitCode}`);

if (failed != 0) exit(1);
console.log("GUARD-OK");
