// The entry of an `--os=solana` program holds the account table in its own frame and hands it to the
// parser, before the program runs, as the reference entry does: no instruction takes the table from
// the program heap. The table holds at most MS_SOL_MAX_ACCOUNTS accounts, 255 by default, and a
// maximum the runtime cannot send (0, or 256 and up) fails the build.
//
// WHY A SUBPROCESS: the observable is the entry the compiler emits and the build of the runtime
// header, which a program's own tests cannot reach. The compiler under test is $MSC, else `./msc`.
// A host without the SBF toolchain prints GUARD-SKIP after the emission checks, which the runner
// reports as unscored.
//
// RED MEANS: the entry stopped declaring the table or parsing into it before MsMain, or an
// out-of-range maximum builds.
import { execFileResult, ExecFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSolanaEntryTable`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/prog.ms`, "import { instructionData, logU64 } from \"std/solana\";\nfunction main(): void { logU64(instructionData().length as uint64); }\nmain();\n");

function build(args: string[]): ExecFileResult {
	const all: string[] = ["build", "prog.ms", "--os=solana"];
	for (const a of args) all.push(a);
	return execFileResult(msc, all, dir);
}

function dispatcher(): string {
	for (const mode of ["debug", "release"]) {
		const path = `${dir}/out/${mode}/_dispatch.c`;
		if (!exists(path)) continue;
		const text = readFile(path);
		if (text.ok) return text.value;
	}
	return "";
}

const emitted = build(["--emit=c"]);
if (emitted.exitCode != 0) {
	report(`--emit=c failed: ${emitted.output}${emitted.errorOutput}`);
	exit(1);
}

const text = dispatcher();
const entry = text.indexOf("uint64_t entrypoint(const uint8_t* input) {");
if (entry < 0) {
	report("the emitted dispatcher has no entrypoint");
	exit(1);
}
const body = text.slice(entry, text.length);
const declared = body.indexOf("uint64_t accounts[MS_SOL_MAX_ACCOUNTS];");
const parsed = body.indexOf("msSolParse(accounts);");
const started = body.indexOf("MsMain();");
if (declared < 0) report("the entry does not declare the account table in its frame");
if (parsed < 0) report("the entry does not parse the input into the table");
if (started < 0) report("the entry does not call MsMain");
if (declared >= 0 && parsed >= 0 && started >= 0 && !(declared < parsed && parsed < started)) {
	report("the entry must declare the table, parse into it, then call MsMain");
}
if (!text.contains("#include \"runtime/solana/solana.h\"")) report("the dispatcher does not include the parser");
if (failed != 0) exit(1);

const probe = build(["--output=default.so"]);
if (probe.exitCode != 0 && (probe.output + probe.errorOutput).includes("--os=solana requires ")) {
	console.log("GUARD-SKIP no SBF toolchain on this host");
	exit(0);
}
if (probe.exitCode != 0) report(`default build failed: ${probe.output}${probe.errorOutput}`);

for (const bad of ["0", "256"]) {
	const refused = build([`--passC=-DMS_SOL_MAX_ACCOUNTS=${bad}`, `--output=bad${bad}.so`]);
	if (refused.exitCode == 0) report(`MS_SOL_MAX_ACCOUNTS=${bad} built`);
	else if (!(refused.output + refused.errorOutput).includes("MS_SOL_MAX_ACCOUNTS is 1 to 255")) {
		report(`MS_SOL_MAX_ACCOUNTS=${bad} failed without naming the limit: ${refused.output}${refused.errorOutput}`);
	}
}
for (const good of ["1", "255"]) {
	const built = build([`--passC=-DMS_SOL_MAX_ACCOUNTS=${good}`, `--output=good${good}.so`]);
	if (built.exitCode != 0) report(`MS_SOL_MAX_ACCOUNTS=${good} did not build: ${built.output}${built.errorOutput}`);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
