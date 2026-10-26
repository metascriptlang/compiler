// A cursor survives a call whose write summary misses the slot it reads: `const t = o.value`
// across `bump(o)`, which writes only `line`, takes no copy of `value`, and
// `a.kids.push(mk(i))` takes no counted receiver temp. A callee that may write the slot, through
// the same object, an alias, a global, a hook, an override or a function value, keeps its count.
// NIM-REF AN-36 (a borrow survives a write to the location it borrows from).
//
// WHY A SUBPROCESS: the observable is the emitted C of each routine. The compiler under test is
// $MSC, else `./msc`; the C is read from `--emit=c`.
//
// RED PRE-FIX: `kept` copied `o.value` and `pushes` increfed its receiver array.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardCursorOtherSlot`;
const program = `${root}/src/test/corpus/programs/cursorSurvivesCalleeWritingOtherSlot.ms`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function emittedFile(cell: string): string {
	const where = `${cell}/out/debug`;
	if (!exists(where)) return "";
	for (const entry of readDir(where)) {
		if (entry.endsWith("ZmainOms.c")) return `${where}/${entry}`;
	}
	return "";
}

function body(lines: string[], name: string): string[] {
	const found: string[] = [];
	let inside = false;
	for (const line of lines) {
		if (!inside && line.startsWith("MS_LIB_PRIVATE ") && line.includes(` ${name}__`) && line.endsWith(") {")) inside = true;
		if (inside) found.push(line);
		if (inside && line == "}") break;
	}
	return found;
}

function count(lines: string[], needle: string): int32 {
	let n = 0;
	for (const line of lines) {
		if (line.includes(needle)) n += 1;
	}
	return n;
}

removeAll(dir);
ensureDir(dir);
const source = readFile(program);
if (!source.ok) {
	report(`cannot read ${program}`);
	exit(1);
}
writeFile(`${dir}/main.ms`, source.value);
const built = execFileResult(msc, ["build", "main.ms", "--emit=c", "--output=main.c"], dir);
if (built.exitCode != 0) {
	report(`--emit=c failed: ${built.output}${built.errorOutput}`);
	exit(1);
}
const file = emittedFile(dir);
const text = readFile(file);
if (!text.ok) {
	report("no emitted C module for the program");
	exit(1);
}
const lines = text.value.split("\n");

const kept = body(lines, "kept");
if (kept.length == 0) report("no C body for kept");
else if (count(kept, "msStringCopy(") != 0) report("kept copies the field it reads across a callee that writes another field");

const pushes = body(lines, "pushes");
if (pushes.length == 0) report("no C body for pushes");
else if (count(pushes, "msIncref") != 0) report("pushes counts its receiver array across a callee that writes no element");

const counted = ["detaches", "viaAlias", "viaGlobal", "viaHook", "viaOverride", "viaFnValue"];
for (const name of counted) {
	const b = body(lines, name);
	if (b.length == 0) report(`no C body for ${name}`);
	else if (count(b, "msStringCopy(") + count(b, "msIncref") == 0) report(`${name} lost the count its callee's write needs`);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
