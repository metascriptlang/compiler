import { execFileResult, cwd, exit, env, cmdExists } from "std/process";
import { writeFile, readFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardJsBundleKeepsOnlyWhatRuns`;

const JSON_PARSER = "function parseJson__";
const ERROR_CLASS = "class Error__";
const RAW_BODY_FUNCTION = "function intPrefix__";
const LITERAL_STATICS_CLASS = "class Math__";
const RAW_FUNCTION_BLOCK = "function msBufLoad";
interface BundleProgram {
	name: string;
	source: string;
	output: string;
	required: string[];
	forbidden: string[];
}

const PROGRAMS: BundleProgram[] = [
	{
		name: "hello",
		source: `console.log("hello");\n`,
		output: "hello",
		required: [],
		forbidden: [JSON_PARSER, ERROR_CLASS, RAW_BODY_FUNCTION, LITERAL_STATICS_CLASS, RAW_FUNCTION_BLOCK],
	},
	{
		name: "parses",
		source: `interface Point { x: number; y: number; }
const parsed = JSON.parse<Point>('{"x": 1, "y": 2}');
function unusedHelper(): string { return "never"; }
class Used { label(): string { return "used"; } }
class Unused { label(): string { return unusedHelper(); } }
if (parsed.ok) console.log(parsed.value.x + parsed.value.y, new Used().label());
`,
		output: "3 used",
		required: [JSON_PARSER, "class Used__"],
		forbidden: ["class Unused__", "function unusedHelper__"],
	},
];
const MODES = ["", "--danger"];

let failed = 0;

if (!cmdExists("node")) {
	console.log("GUARD-SKIP node is not on PATH");
	exit(0);
}

removeAll(dir);
ensureDir(dir);

for (const program of PROGRAMS) {
	writeFile(`${dir}/${program.name}.ms`, program.source);
	for (const mode of MODES) {
		const tag = `${program.name} ${mode == "" ? "debug" : mode}`;
		const bundle = `${dir}/${program.name}${mode.replace("--", "-")}.mjs`;
		const args = ["build", `${program.name}.ms`, "--target=js", `--output=${bundle}`];
		if (mode != "") args.push(mode);
		const build = execFileResult(msc, args, dir);
		if (build.exitCode != 0) {
			console.log(`GUARD-FAIL ${tag}: build failed\n${build.output}${build.errorOutput}`);
			failed = failed + 1;
			continue;
		}
		const run = execFileResult("node", [bundle]);
		if (run.exitCode != 0 || run.output.trim() != program.output) {
			console.log(`GUARD-FAIL ${tag}: node exited ${run.exitCode} printing "${run.output.trim()}${run.errorOutput.trim()}", expected "${program.output}"`);
			failed = failed + 1;
		}
		const read = readFile(bundle);
		if (!read.ok) {
			console.log(`GUARD-FAIL ${tag}: ${msc} exited 0 without writing ${bundle}`);
			failed = failed + 1;
			continue;
		}
		const text = read.value;
		for (const needle of program.forbidden) {
			if (text.includes(needle)) {
				console.log(`GUARD-FAIL ${tag}: the bundle holds "${needle}", which nothing that runs names`);
				failed = failed + 1;
			}
		}
		for (const needle of program.required) {
			if (!text.includes(needle)) {
				console.log(`GUARD-FAIL ${tag}: the bundle has no "${needle}", so the check read nothing`);
				failed = failed + 1;
			}
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
