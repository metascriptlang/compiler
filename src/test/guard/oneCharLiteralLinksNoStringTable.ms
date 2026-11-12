import { execFileResult, cwd, exit, env, cmdExists, platform } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardOneCharLiteralLinksNoStringTable`;

interface CharProgram {
	name: string;
	source: string;
	output: string;
	required: string[];
	forbidden: string[];
}

const PROGRAMS: CharProgram[] = [
	{
		name: "indexes",
		source: `const word = "hello";\nconsole.log("x", word[1], "y");\n`,
		output: "x e y",
		required: ["msCharPayloads", "msCharLit120"],
		forbidden: ["msCharTable"],
	},
	{
		name: "literals",
		source: `console.log("x", "y");\n`,
		output: "x y",
		required: ["msCharLit120", "msCharLit32"],
		forbidden: ["msCharTable", "msCharPayloads", "msCharLit65"],
	},
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
	writeFile(`${dir}/${program.name}.ms`, program.source);
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
		const run = execFileResult(path, []);
		if (run.exitCode != 0 || run.output.trim() != program.output) {
			console.log(`GUARD-FAIL ${tag}: the program exited ${run.exitCode} printing "${run.output.trim()}", expected "${program.output}"`);
			failed = failed + 1;
		}
		const linked: string[] = [];
		for (const line of execFileResult("nm", [path]).output.split("\n")) {
			const fields = line.trim().split(" ");
			const symbol = fields[fields.length - 1];
			linked.push((symbol.startsWith("_") ? symbol.slice(1) : symbol).split(".")[0]);
		}
		for (const name of program.forbidden) {
			if (linked.includes(name)) {
				console.log(`GUARD-FAIL ${tag}: the program links ${name}`);
				failed = failed + 1;
			}
		}
		for (const name of program.required) {
			if (!linked.includes(name)) {
				console.log(`GUARD-FAIL ${tag}: no ${name} in the symbol table`);
				failed = failed + 1;
			}
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
