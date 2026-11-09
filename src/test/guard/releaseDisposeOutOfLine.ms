// Every generic ref release decides inline and disposes through one out-of-line call. The
// reference inlines only the last-ref check (`nimDecRefIsLast`) and calls `nimDestroyAndDispose`;
// a copy of the destroy dispatch and the free path at each of msc's ~146k release sites costs
// a quarter of its .text. This compiles one function per release macro of
// runtime/core/system.h at -O3 and reads the object's symbol table: each must call its
// out-of-line last-ref routine, and none may reach `msUnownedOutlives`, which only the inline
// dispose calls. The four plain releases also leave the cycle-root unregister of a last ref to
// that routine, so none may call `msUnregisterCycle` itself; the edge release keeps it, because
// its deferred path destroys without the routine.
//
// WHY A SUBPROCESS: the observable is the object code a release site expands to. A host without
// `cc` or `nm` prints GUARD-SKIP, which the runner reports as unscored.
//
// RED MEANS: a release macro carries the destroy dispatch, the dispose or the root unregister
// inline again, so every release site in every program grows by that copy.
// RED PRE-FIX: tree 9966bc7d6d35: all five functions reference `msUnownedOutlives` and none calls
// its out-of-line routine (macOS arm64, 2026-11-09). The unregister rows: RED on tree
// 516f13436208, where `msDecref`, `msDecrefAny` and `msDecrefCyclic` call `msUnregisterCycle`
// (macOS arm64, 2026-11-09).
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, cmdExists } from "std/process";
import { writeFile, ensureDir, removeAll } from "std/fs";

const root = cwd();
const dir = `${root}/out/guardReleaseDisposeOutOfLine`;

const SITES = [
	{ name: "releaseDecref", body: "msDecref(p);", call: "msDestroyAndDisposeDyn", rootAtSite: false },
	{ name: "releaseDecrefAny", body: "msDecrefAny(p);", call: "msDestroyAndDisposeDyn", rootAtSite: false },
	{ name: "releaseDecrefCyclic", body: "msDecrefCyclic(p);", call: "msDestroyAndDisposeDyn", rootAtSite: false },
	{ name: "releaseAtomicDecref", body: "msAtomicDecref(p);", call: "msDestroyAndDisposeDyn", rootAtSite: false },
	{ name: "releaseDecrefCyclicEdge", body: "(void)msDecrefCyclicEdge(o, p);", call: "msDestroyAndDisposeDyn", rootAtSite: true },
];
const INLINE_DISPOSE = "msUnownedOutlives";
const ROOT_UNREGISTER = "msUnregisterCycle";

if (!cmdExists("cc") || !cmdExists("nm")) {
	console.log("GUARD-SKIP cc or nm is not on PATH");
	exit(0);
}

removeAll(dir);
ensureDir(dir);

let failed = 0;
for (const site of SITES) {
	const source = `${dir}/${site.name}.c`;
	const object = `${dir}/${site.name}.o`;
	writeFile(source, `#include "runtime/core/system.h"\nvoid ${site.name}(void* o, void* p) { (void)o; ${site.body} }\n`);
	const build = execFileResult("cc", ["-O3", "-c", `-I${root}`, source, "-o", object]);
	if (build.exitCode != 0) {
		console.log(`GUARD-FAIL ${site.name}: cc failed\n${build.output}${build.errorOutput}`);
		failed = failed + 1;
		continue;
	}
	const symbols = execFileResult("nm", [object]);
	let sawCall = false;
	let sawDefinition = false;
	for (const line of symbols.output.split("\n")) {
		const fields = line.trim().split(" ");
		const symbol = fields[fields.length - 1];
		const name = symbol.startsWith("_") ? symbol.slice(1) : symbol;
		if (name == site.name) sawDefinition = true;
		if (name == site.call) sawCall = true;
		if (name == ROOT_UNREGISTER && !site.rootAtSite) {
			console.log(`GUARD-FAIL ${site.name}: \`${site.body}\` unregisters the cycle root inline (${line.trim()})`);
			failed = failed + 1;
		}
		if (name == INLINE_DISPOSE) {
			console.log(`GUARD-FAIL ${site.name}: \`${site.body}\` expands the dispose inline (${line.trim()})`);
			failed = failed + 1;
		}
	}
	if (!sawDefinition) {
		console.log(`GUARD-FAIL ${site.name}: not in the object's symbol table, so the check read nothing`);
		failed = failed + 1;
	} else if (!sawCall) {
		console.log(`GUARD-FAIL ${site.name}: \`${site.body}\` does not call ${site.call}`);
		failed = failed + 1;
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
