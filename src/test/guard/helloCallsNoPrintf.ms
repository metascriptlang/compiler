import { execFileResult, cwd, exit, env, cmdExists } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardHelloCallsNoPrintf`;

const FORMATTER_DATA = "-0X+0X 0X-0x+0x 0x";
interface StaticTarget {
	name: string;
	flags: string[];
	suffix: string;
}
const TARGETS: StaticTarget[] = [
	{ name: "wasi", flags: ["--os=wasm"], suffix: ".wasm" },
	{ name: "musl", flags: ["--os=linux", "--abi=musl"], suffix: "-musl" },
];
interface StaticProgram {
	name: string;
	marker: string;
	source: string;
}
const PROGRAMS: StaticProgram[] = [
	{ name: "hello", marker: "hello", source: `console.log("hello");
` },
	{ name: "coll", marker: "coll", source: `const m = new Map<string, int32>();
m.set("a", 1);
const s = new Set<int32>();
s.add(2);
console.log("coll", m.get("a"), s.has(2));
` },
];

let failed = 0;

if (!cmdExists("grep")) {
	console.log("GUARD-SKIP grep is not on PATH");
	exit(0);
}

function holds(file: string, name: string): boolean {
	return execFileResult("grep", ["-a", "-c", "-F", "-e", name, file]).output.trim() != "0";
}

removeAll(dir);
ensureDir(dir);

for (const program of PROGRAMS) {
	writeFile(`${dir}/${program.name}.ms`, program.source);
	for (const target of TARGETS) {
		const label = `${target.name} ${program.name}`;
		const binary = `${dir}/${program.name}${target.suffix}`;
		const build = execFileResult(msc, ["build", `${program.name}.ms`, "--danger", "--strip", ...target.flags, `--output=${binary}`], dir);
		if (build.exitCode != 0 || !exists(binary)) {
			console.log(`GUARD-FAIL ${label}: build failed\n${build.output}${build.errorOutput}`);
			failed = failed + 1;
			continue;
		}
		if (holds(binary, FORMATTER_DATA)) {
			console.log(`GUARD-FAIL ${label}: a static build links the libc formatter (its prefix table "${FORMATTER_DATA}" is in the binary)`);
			failed = failed + 1;
		}
		if (!holds(binary, program.marker)) {
			console.log(`GUARD-FAIL ${label}: no "${program.marker}" in ${binary}, so the check read nothing`);
			failed = failed + 1;
		}
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
