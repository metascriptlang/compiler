// guard: a spawn thunk reads the parent's env as a view, without an rc op
//
// INVARIANT (ULTRALOCK T4, V4): the routine a worker runs for a spawn takes no count on the env it
//   is handed, on a cell read out of it, or on a local bound to such a read: the parent keeps the
//   env alive until the join. Axes: a held handle and an await of the spawn in a sync routine, an
//   async function, a local bound to an env field, and a thunk that allocates its own cells.
//
// WHY A SUBPROCESS: the observable is the emitted C of each thunk routine. The compiler under
//   test is $MSC, else `./msc`; the C is read from `--emit=c`.
//
// RED MEANS: a thunk counts what it borrows from the parent, so a worker thread races the
//   owner's plain rc on the parent's cells.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSpawnThunkCountsNoEnv`;
const RC_OPS = ["msIncref(", "msDecref(", "msIncRef(", "msDecRef(", "msAtomicIncref(", "msAtomicDecref(", "msAtomicIncRef(", "msAtomicDecRef("];
const THUNKS = ["dollarlifted_held_", "dollarlifted_fused_", "dollarlifted_inAsync_fexpr", "dollarlifted_viaLocal_", "dollarlifted_makesOwn_"];

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

const source = "class Child { v: int32; constructor(v: int32) { this.v = v; } }\n"
	+ "class Holder { child: Child; constructor(c: Child) { this.child = c; } }\n"
	+ "function held(): int32 {\n\tconst obj = new Holder(new Child(1));\n\tconst f = spawn(() => obj.child.v + 1);\n\treturn await f;\n}\n"
	+ "function fused(): int32 {\n\tconst obj = new Holder(new Child(2));\n\treturn await spawn(() => obj.child.v + 1);\n}\n"
	+ "async function inAsync(): Promise<int32> {\n\tconst obj = new Holder(new Child(3));\n\tconst f = spawn(() => { const c = obj.child; return c.v; });\n\treturn await f;\n}\n"
	+ "function viaLocal(): int32 {\n\tconst obj = new Holder(new Child(4));\n\tconst f = spawn(() => { const c = obj.child; let s: int32 = 0; for (let r = 0; r < 10; r += 1) s = s + c.v; return s; });\n\treturn await f;\n}\n"
	+ "function makesOwn(): int32 {\n\tconst obj = new Holder(new Child(5));\n\tconst f = spawn(() => { const h = new Holder(new Child(obj.child.v)); return h.child.v; });\n\treturn await f;\n}\n"
	+ "console.log(`${held()} ${fused()} ${await inAsync()} ${viaLocal()} ${makesOwn()}`);\n";

function emitted(): string {
	removeAll(dir);
	ensureDir(dir);
	writeFile(`${dir}/main.ms`, source);
	const built = execFileResult(msc, ["build", "main.ms", "--emit=c", "--output=main.c"], dir);
	if (built.exitCode != 0) {
		report(`--emit=c failed: ${built.output}${built.errorOutput}`);
		return "";
	}
	const where = `${dir}/out/debug`;
	if (!exists(where)) {
		report(`no ${where}`);
		return "";
	}
	for (const entry of readDir(where)) {
		if (entry.endsWith("mainOms.c")) {
			const r = readFile(`${where}/${entry}`);
			return r.ok ? r.value : "";
		}
	}
	report("no C file for main.ms in the emitted C");
	return "";
}

// A thunk is defined as `MS_LIB_PRIVATE void* <prefix>...(void* _envP) {`.
function thunkBody(text: string, prefix: string): string {
	let at = text.indexOf("\nMS_LIB_PRIVATE ", 0);
	while (at >= 0) {
		const eol = text.indexOf("\n", at + 1);
		const line = text.slice(at + 1, eol < 0 ? text.length : eol);
		if (line.contains(` ${prefix}`) && line.endsWith("(void* _envP) {")) {
			const end = text.indexOf("\n}\n", eol);
			return text.slice(at + 1, end < 0 ? text.length : end);
		}
		at = text.indexOf("\nMS_LIB_PRIVATE ", at + 1);
	}
	return "";
}

function isIdentChar(c: string): boolean {
	return (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_";
}

// The local a statement `(name = ...` or `name = ...` assigns.
function assignedName(line: string): string {
	let s = line.trim();
	if (s.startsWith("(")) s = s.slice(1, s.length);
	let end = 0;
	while (end < s.length && isIdentChar(s.charAt(end))) end += 1;
	if (end == 0 || !s.slice(end, s.length).startsWith(" = ")) return "";
	return s.slice(0, end);
}

function rcOpTarget(line: string): string {
	for (const op of RC_OPS) {
		const at = line.indexOf(op);
		if (at < 0 || (at > 0 && isIdentChar(line.charAt(at - 1)))) continue;
		const start = at + op.length;
		const close = line.indexOf(")", start);
		return line.slice(start, close < 0 ? line.length : close);
	}
	return "";
}

function envCounts(body: string): string {
	const fromEnv: string[] = ["_envP"];
	for (const line of body.split("\n")) {
		if (!line.contains("_envP")) continue;
		const name = assignedName(line);
		if (name != "" && !fromEnv.includes(name)) fromEnv.push(name);
	}
	for (const line of body.split("\n")) {
		const target = rcOpTarget(line);
		if (target == "") continue;
		if (target.contains("_envP")) return line.trim();
		for (const name of fromEnv) {
			if (target == name) return line.trim();
		}
	}
	return "";
}

const text = emitted();
if (text != "") {
	for (const prefix of THUNKS) {
		const body = thunkBody(text, prefix);
		if (body == "") {
			report(`thunk ${prefix}* not found in the emitted C`);
			continue;
		}
		const op = envCounts(body);
		if (op != "") report(`${prefix}*: ${op}`);
	}
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
