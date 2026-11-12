import { execFileResult, cwd, exit, env, cmdExists, platform } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardAcyclicProgramLinksNoCycleCollector`;

const FORBIDDEN = "msRegisterCycle";
const REQUIRED = "main";
const MODES = ["--mm=drc", "--mm=none"];
const PROGRAM = `const m = new Map<string, int32>();
m.set("k", 1);
const s = new Set<int32>();
s.add(2);
console.log(m.size, s.size);
`;

let failed = 0;

if (!cmdExists("nm")) {
	console.log("GUARD-SKIP nm is not on PATH");
	exit(0);
}
if (platform == "windows") {
	console.log("GUARD-SKIP the Windows link keeps its symbols in a .pdb, which nm does not read");
	exit(0);
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/acyclic.ms`, PROGRAM);

for (const mode of MODES) {
	const binary = `${dir}/acyclic${mode.replace("--mm=", "-")}`;
	const build = execFileResult(msc, ["build", "acyclic.ms", "--danger", mode, `--output=${binary}`], dir);
	if (build.exitCode != 0) {
		console.log(`GUARD-FAIL ${mode}: build failed\n${build.output}${build.errorOutput}`);
		failed = failed + 1;
		continue;
	}
	const path = exists(`${binary}.exe`) ? `${binary}.exe` : binary;
	if (!exists(path)) {
		console.log(`GUARD-FAIL ${mode}: ${msc} exited 0 without writing ${path}`);
		failed = failed + 1;
		continue;
	}
	const run = execFileResult(path, []);
	if (run.exitCode != 0 || run.output.trim() != "1 1") {
		console.log(`GUARD-FAIL ${mode}: the program exited ${run.exitCode} printing "${run.output.trim()}", expected "1 1"`);
		failed = failed + 1;
	}
	let sawRequired = false;
	for (const line of execFileResult("nm", [path]).output.split("\n")) {
		const fields = line.trim().split(" ");
		const symbol = fields[fields.length - 1];
		const name = (symbol.startsWith("_") ? symbol.slice(1) : symbol).split(".")[0];
		if (name == REQUIRED) sawRequired = true;
		if (name == FORBIDDEN) {
			console.log(`GUARD-FAIL ${mode}: a program with no cyclic type links ${name} (${line.trim()})`);
			failed = failed + 1;
		}
	}
	if (!sawRequired) {
		console.log(`GUARD-FAIL ${mode}: no ${REQUIRED} in the symbol table, so the check read nothing`);
		failed = failed + 1;
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
