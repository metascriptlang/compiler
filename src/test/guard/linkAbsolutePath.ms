// An absolute `@link` path names the archive itself; a relative one resolves from the declaring
// module's directory, as before.
//
// WHY A SUBPROCESS: the observable is the link of a built program against an archive at an
// absolute path, which only exists once this guard has built it. The compiler under test is
// $MSC, else `./msc`; the archive is built with the host `cc` and `ar`.
//
// RED PRE-FIX: the absolute path was joined to the module's directory and the link failed with
// "<moduleDir>/<absolute path>: file not found". GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, cmdExists } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd().replaceAll("\\", "/");
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardLinkAbsolutePath`;

if (!cmdExists("cc") || !cmdExists("ar")) {
	console.log("GUARD-SKIP no host cc/ar to build the archive");
	exit(0);
}

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

removeAll(dir);
ensureDir(`${dir}/lib`);
writeFile(`${dir}/lib/lp.c`, "int linkProbe(void) { return 42; }\n");
writeFile(`${dir}/lp.h`, "int linkProbe(void);\n");
const compiled = execFileResult("cc", ["-c", "lp.c", "-o", "lp.o"], `${dir}/lib`);
const archived = execFileResult("ar", ["rcs", "liblp.a", "lp.o"], `${dir}/lib`);
if (compiled.exitCode != 0 || archived.exitCode != 0) report(`archive: ${compiled.errorOutput}${archived.errorOutput}`);

const probeImport = "import { linkProbe } from \"./lp.h\";\n";
writeFile(`${dir}/abs.ms`, probeImport + "@link(\"" + dir + "/lib/liblp.a\");\nconsole.log(linkProbe());\n");
writeFile(`${dir}/rel.ms`, probeImport + "@link(\"lib/liblp.a\");\nconsole.log(linkProbe());\n");

function lastLine(file: string): string {
	const r = execFileResult(msc, ["run", file], dir);
	if (r.exitCode != 0) return `exit ${r.exitCode}: ${r.output}${r.errorOutput}`;
	const lines = r.output.trim().split("\n");
	return lines[lines.length - 1].trim();
}

const absolute = lastLine("abs.ms");
if (absolute != "42") report(`absolute @link: ${absolute}`);
const relative = lastLine("rel.ms");
if (relative != "42") report(`relative @link: ${relative}`);

if (failed != 0) exit(1);
console.log("GUARD-OK");
