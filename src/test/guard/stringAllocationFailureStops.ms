// A string whose payload the allocator cannot provide stops the program with "Error: out of
// memory", on a concatenation and on a template literal.
//
// WHY A SUBPROCESS: the allocation fails only under an address-space limit the probe sets on
// itself (RLIMIT_AS, enforced on Linux only), and the observable is its exit and output. The
// compiler under test is $MSC, else `./msc`.
//
// RED PRE-FIX: the payload came back NULL and the copy into it panicked with "member access
// within null pointer of type 'msStrPayload'". GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, platform } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

if (platform != "linux") {
	console.log("GUARD-SKIP RLIMIT_AS is enforced only on Linux");
	exit(0);
}

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardStringAllocationFailure`;

const limitHeader = `#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/resource.h>

static inline int32_t guardLimitAddressSpace(int32_t extraMb) {
	unsigned long pages = 0;
	FILE* f = fopen("/proc/self/statm", "r");
	if (f == NULL) return -1;
	int got = fscanf(f, "%lu", &pages);
	fclose(f);
	if (got != 1) return -1;
	struct rlimit r;
	r.rlim_cur = (rlim_t)pages * (rlim_t)sysconf(_SC_PAGESIZE) + (rlim_t)extraMb * 1024 * 1024;
	r.rlim_max = r.rlim_cur;
	return setrlimit(RLIMIT_AS, &r);
}
`;

function program(join: string): string {
	return `@include("./limit.h");
extern function guardLimitAddressSpace(extraMb: int32): int32;

let s = "x";
for (let i = 0; i < 28; i++) s = s + s;
if (guardLimitAddressSpace(128) != 0) {
	console.log("setrlimit failed");
	process.exit(3);
}
console.log("before the allocation");
const t = ${join};
console.log(\`string length \${t.length}\`);
`;
}

let failed = 0;

function run(label: string, join: string): void {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	writeFile(`${cell}/limit.h`, limitHeader);
	writeFile(`${cell}/main.ms`, program(join));
	const built = execFileResult(msc, ["build", "main.ms", "--output=main"], cell);
	if (built.exitCode != 0) {
		console.log(`GUARD-FAIL ${label}: msc build exited ${built.exitCode.toString()}\n${built.output}${built.errorOutput}`);
		failed = failed + 1;
		return;
	}
	const ran = execFileResult(`${cell}/main`, [], cell);
	if (ran.exitCode != 1 || ran.output.trim() != "before the allocation" || !ran.errorOutput.contains("Error: out of memory")) {
		console.log(`GUARD-FAIL ${label}: the program exited ${ran.exitCode.toString()}, printed '${ran.output.trim()}' and '${ran.errorOutput.trim()}', expected exit 1, 'before the allocation' and 'Error: out of memory'`);
		failed = failed + 1;
	}
}

removeAll(dir);
ensureDir(dir);
run("concat", "s + s");
run("template", "`${s}${s}`");
removeAll(dir);

if (failed > 0) exit(1);
console.log("GUARD-OK");
