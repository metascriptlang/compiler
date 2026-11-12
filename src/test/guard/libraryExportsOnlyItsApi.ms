import { execFileResult, cwd, exit, env, cmdExists, platform } from "std/process";
import { writeFile, ensureDir, removeAll, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv == "" ? `${root}/msc` : mscEnv.startsWith(".") ? `${root}/${mscEnv}` : mscEnv;
const dir = `${root}/out/guardLibraryExportsOnlyItsApi`;

const API = "guardLibraryAdd";
const FOREIGN = "guardForeignValue";
const HOST_CALLS = ["MsMain", "MsDestroyGlobals", "msDrainAtExit", "msReportOrphanFailures"];
const MODULE_INITS = ["__DatInit000", "__Init000"];
const PROGRAM = `@compile("./foreign.c");

export function moduleOnly(a: int32): int32 {
	return a * 3;
}

@exportName("${API}")
export function add(a: int32, b: int32): int32 {
	return moduleOnly(a) + b;
}
`;
const FOREIGN_SOURCE = `int ${FOREIGN}(void) { return 7; }
`;
const HOST = `import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
lib.MsMain()
print(lib.${API}(13, 3), lib.${FOREIGN}())
lib.msDrainAtExit()
print(lib.msReportOrphanFailures())
lib.MsDestroyGlobals()
`;

if (!cmdExists("nm")) {
	console.log("GUARD-SKIP nm is not on PATH");
	exit(0);
}
if (platform == "windows") {
	console.log("GUARD-SKIP nm does not read a DLL's export table");
	exit(0);
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/library.ms`, PROGRAM);
writeFile(`${dir}/foreign.c`, FOREIGN_SOURCE);
writeFile(`${dir}/host.py`, HOST);

const library = `${dir}/libguard${platform == "darwin" ? ".dylib" : ".so"}`;
const build = execFileResult(msc, ["build", "library.ms", "--danger", "--app=lib", `--output=${library}`], dir);
if (build.exitCode != 0 || !exists(library)) {
	console.log(`GUARD-FAIL build failed\n${build.output}${build.errorOutput}`);
	exit(1);
}

function isExpected(name: string): boolean {
	if (name == API || name == FOREIGN || HOST_CALLS.includes(name)) return true;
	for (const suffix of MODULE_INITS) {
		if (name.endsWith(suffix)) return true;
	}
	return platform != "darwin" && name.startsWith("_");
}

const exported: string[] = [];
const unexpected: string[] = [];
const listing = platform == "darwin" ? ["-gU", library] : ["-D", "--defined-only", library];
for (const line of execFileResult("nm", listing).output.split("\n")) {
	const fields = line.trim().split(" ");
	if (fields.length < 3) continue;
	const symbol = fields[fields.length - 1];
	const name = platform == "darwin" && symbol.startsWith("_") ? symbol.slice(1) : symbol;
	exported.push(name);
	if (!isExpected(name)) unexpected.push(name);
}

let failed = 0;
for (const name of [API, FOREIGN, ...HOST_CALLS]) {
	if (!exported.includes(name)) {
		console.log(`GUARD-FAIL the library does not export ${name} (${exported.length} symbols exported)`);
		failed = failed + 1;
	}
}
if (unexpected.length > 0) {
	console.log(`GUARD-FAIL the library exports ${unexpected.length} symbols outside its API, among them ${unexpected.slice(0, 5).join(", ")}`);
	failed = failed + 1;
}

if (cmdExists("python3")) {
	const run = execFileResult("python3", ["host.py", library], dir);
	if (run.exitCode != 0 || run.output.trim() != "42 7\n0") {
		console.log(`GUARD-FAIL a host loading the library exited ${run.exitCode} printing "${run.output.trim()}", expected "42 7" then "0"\n${run.errorOutput}`);
		failed = failed + 1;
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
