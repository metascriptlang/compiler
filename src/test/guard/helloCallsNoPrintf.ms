import { execFileResult, cwd, exit, env, cmdExists } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardHelloCallsNoPrintf`;

const FORMATTER_DATA = "-0X+0X 0X-0x+0x 0x";
const REQUIRED = "hello";
interface StaticTarget {
	name: string;
	flags: string[];
	output: string;
}
const TARGETS: StaticTarget[] = [
	{ name: "wasi", flags: ["--os=wasm"], output: "hello.wasm" },
	{ name: "musl", flags: ["--os=linux", "--abi=musl"], output: "hello-musl" },
];
const PROGRAM = `console.log("hello");
`;

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
writeFile(`${dir}/hello.ms`, PROGRAM);

for (const target of TARGETS) {
	const binary = `${dir}/${target.output}`;
	const build = execFileResult(msc, ["build", "hello.ms", "--danger", "--strip", ...target.flags, `--output=${binary}`], dir);
	if (build.exitCode != 0 || !exists(binary)) {
		console.log(`GUARD-FAIL ${target.name}: build failed\n${build.output}${build.errorOutput}`);
		failed = failed + 1;
		continue;
	}
	if (holds(binary, FORMATTER_DATA)) {
		console.log(`GUARD-FAIL ${target.name}: a static hello links the libc formatter (its prefix table "${FORMATTER_DATA}" is in the binary)`);
		failed = failed + 1;
	}
	if (!holds(binary, REQUIRED)) {
		console.log(`GUARD-FAIL ${target.name}: no "${REQUIRED}" in ${binary}, so the check read nothing`);
		failed = failed + 1;
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
