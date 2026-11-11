// A program that converts case in one direction links only that direction's Unicode tables:
// `toUpperCase` alone links no lower-case table and no Final_Sigma spans, `toLowerCase` alone no
// upper-case table. The reference expands its string conversion once per direction, so each
// direction reaches only the data it reads. This builds both programs with --lto=off at --danger
// and --release and reads the linked symbol table: the other direction's tables may not remain,
// and the entry point and its own table must, so a stripped binary or a renamed table cannot pass.
//
// WHY A SUBPROCESS: the observable is the linked binary's symbols. The compiler under test is
// $MSC, else `./msc`. A host without `nm` prints GUARD-SKIP, which the runner reports as unscored.
//
// RED MEANS: the case kernels in runtime/core/stringCase.c take the direction at run time again
// in a body both entry points share, so every program that converts case carries both directions'
// tables (7,880 B of lower-case data in an upper-only program on macOS arm64).
// RED PRE-FIX: the upper program links `msLowerFull`, `msLowerRuns`, `msCasedSpans`,
// `msCaseIgnorableSpans`; the lower program `msUpperFull`, `msUpperRuns`. GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, cmdExists, platform } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardCaseDirectionLinksItsTablesOnly`;

const UPPER_TABLES = ["msUpperFull", "msUpperRuns"];
const LOWER_TABLES = ["msLowerFull", "msLowerRuns", "msCasedSpans", "msCaseIgnorableSpans"];
const PROGRAMS = [
	{ name: "upper", call: "toUpperCase", required: ["msStringToUpperCase", "msUpperRuns"], forbidden: LOWER_TABLES },
	{ name: "lower", call: "toLowerCase", required: ["msStringToLowerCase", "msLowerRuns"], forbidden: UPPER_TABLES },
];
const MODES = ["--danger", "--release"];

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

for (const program of PROGRAMS) {
	writeFile(
		`${dir}/${program.name}.ms`,
		`import { argv } from "std/process";\nconsole.log(("Größe Σ " + argv.length.toString()).${program.call}());\n`,
	);
	for (const mode of MODES) {
		const tag = `${program.name} ${mode}`;
		const binary = `${dir}/${program.name}${mode.replace("--", "-")}`;
		const build = execFileResult(msc, ["build", `${program.name}.ms`, mode, "--lto=off", `--output=${binary}`], dir);
		if (build.exitCode != 0) {
			console.log(`GUARD-FAIL ${tag}: build failed\n${build.output}${build.errorOutput}`);
			failed = failed + 1;
			continue;
		}
		const path = exists(`${binary}.exe`) ? `${binary}.exe` : binary;
		if (!exists(path)) {
			console.log(`GUARD-FAIL ${tag}: ${msc} exited 0 without writing ${path}`);
			failed = failed + 1;
			continue;
		}
		const linked = new Set<string>();
		for (const line of execFileResult("nm", [path]).output.split("\n")) {
			const fields = line.trim().split(" ");
			const symbol = fields[fields.length - 1];
			const name = (symbol.startsWith("_") ? symbol.slice(1) : symbol).split(".")[0];
			if (program.forbidden.includes(name) && !linked.has(name)) {
				console.log(`GUARD-FAIL ${tag}: links ${name} (${line.trim()})`);
				failed = failed + 1;
			}
			linked.add(name);
		}
		for (const name of program.required) {
			if (!linked.has(name)) {
				console.log(`GUARD-FAIL ${tag}: no ${name} in the symbol table, so the check read nothing`);
				failed = failed + 1;
			}
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
