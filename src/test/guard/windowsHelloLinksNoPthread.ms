import { execFileResult, cwd, exit, env, cmdExists } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardWindowsHelloLinksNoPthread`;

const WINPTHREADS_DATA = "SetThreadDescription";
const REQUIRED = "hello";
const PROGRAM = `console.log("hello");
`;

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

const binary = `${dir}/hello.exe`;
const build = execFileResult(msc, ["build", "hello.ms", "--os=windows", "--danger", "--strip", `--output=${dir}/hello`], dir);
if (build.exitCode != 0 || !exists(binary)) {
	console.log(`GUARD-FAIL build failed\n${build.output}${build.errorOutput}`);
	exit(1);
}
if (holds(binary, WINPTHREADS_DATA)) {
	console.log(`GUARD-FAIL a Windows hello links winpthreads (its start-up lookup "${WINPTHREADS_DATA}" is in the binary)`);
	exit(1);
}
if (!holds(binary, REQUIRED)) {
	console.log(`GUARD-FAIL no "${REQUIRED}" in ${binary}, so the check read nothing`);
	exit(1);
}
console.log("GUARD-OK");
