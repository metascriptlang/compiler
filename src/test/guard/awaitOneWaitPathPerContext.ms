// guard: one wait path per `await`, chosen by the context it is written in
//
// INVARIANT (ULTRALOCK S2): a sync routine waits at each await site with exactly one blocking
//   wait intrinsic, pumping its own loop; an async function and an actor method never block:
//   their step routine has no blocking wait and one resume state per await site. Each context
//   awaits three operand kinds: a spawn, an async call or an actor CALL, and Promise.all.
//
// WHY A SUBPROCESS: the observable is the emitted C of each routine. The compiler under test
//   is $MSC, else `./msc`; the C is read from `--emit=c`.
//
// RED MEANS: an await site took a second wait path (a blocking wait inside a step routine, or
//   two waits for one site), or lost its resume state; awaitLower.ms chose the path from
//   something other than the operand and the context.

import { execFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardAwaitOneWaitPath`;
const BLOCKING_WAITS = ["msAwaitSlotWait(", "msWaitForReady(", "msWaitFor(", "msAwaitGroupBlocking(", "msAwaitGroupBlockingWithDeadline("];
const SITES = 3;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function emitMain(label: string, source: string): string {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	writeFile(`${cell}/main.ms`, source);
	const built = execFileResult(msc, ["build", "main.ms", "--emit=c", "--output=main.c"], cell);
	if (built.exitCode != 0) {
		report(`${label}: --emit=c failed: ${built.output}${built.errorOutput}`);
		return "";
	}
	const where = `${cell}/out/debug`;
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
	report(`${label}: no mainOms C file`);
	return "";
}

// The definition line of a routine: `MS_LIB_PRIVATE <type> <prefix>...(<params>) {`.
function routineBody(text: string, prefix: string): string {
	let at = text.indexOf(`\nMS_LIB_PRIVATE `, 0);
	while (at >= 0) {
		const eol = text.indexOf("\n", at + 1);
		const line = text.slice(at + 1, eol < 0 ? text.length : eol);
		const name = line.indexOf(prefix);
		if (name > 0 && line.endsWith(" {") && line.charAt(name - 1) == " " || name > 0 && line.endsWith(" {") && line.charAt(name - 1) == "*") {
			const end = text.indexOf("\n}\n", eol);
			return text.slice(at + 1, end < 0 ? text.length : end);
		}
		at = text.indexOf(`\nMS_LIB_PRIVATE `, at + 1);
	}
	return "";
}

function count(text: string, needle: string): int32 {
	let n: int32 = 0;
	let at = text.indexOf(needle, 0);
	while (at >= 0) {
		n += 1;
		at = text.indexOf(needle, at + needle.length);
	}
	return n;
}

function blockingWaits(body: string): int32 {
	let n: int32 = 0;
	for (const w of BLOCKING_WAITS) n += count(body, ` ${w}`) + count(body, `\t${w}`) + count(body, `(${w}`);
	return n;
}

function isDigit(c: string): boolean {
	return c >= "0" && c <= "9";
}

// A resume state is a store of a positive constant into the frame's state field.
function resumeStates(body: string): int32 {
	const seen: string[] = [];
	const key = "dollarstate";
	let at = body.indexOf(key, 0);
	while (at >= 0) {
		const eq = body.indexOf(" = ", at);
		const nl = body.indexOf("\n", at);
		if (eq > 0 && (nl < 0 || eq < nl) && body.slice(at, eq).indexOf(" ") < 0 && body.slice(at, eq).indexOf("=") < 0) {
			let end = eq + 3;
			while (end < body.length && isDigit(body.charAt(end))) end += 1;
			const value = body.slice(eq + 3, end);
			if (value != "" && value != "0" && !seen.includes(value)) seen.push(value);
		}
		at = body.indexOf(key, at + key.length);
	}
	return seen.length as int32;
}

removeAll(dir);
ensureDir(dir);

const helpers = "function work(n: int32): int32 { return n + 1; }\nasync function asy(n: int32): Promise<int32> { return n * 2; }\n";

const syncC = emitMain("sync", helpers
	+ "function syncSite(): int32 {\n"
	+ "\tconst a = await spawn(() => work(1));\n"
	+ "\tconst b = await asy(3);\n"
	+ "\tconst c = await Promise.all([spawn(() => work(2)), spawn(() => work(3))]);\n"
	+ "\treturn a + b + c[0] + c[1];\n}\n"
	+ "console.log(`${syncSite()}`);\n");
const syncBody = routineBody(syncC, "syncSite__");
if (syncC != "" && syncBody == "") report("sync: routine syncSite not found in the emitted C");
if (syncBody != "") {
	const waits = blockingWaits(syncBody);
	if (waits != SITES) report(`sync: ${waits} blocking waits for ${SITES} await sites`);
	if (resumeStates(syncBody) != 0) report("sync: a sync routine got resume states");
}

const asyncC = emitMain("async", helpers
	+ "async function asyncSite(): Promise<int32> {\n"
	+ "\tconst a = await spawn(() => work(1));\n"
	+ "\tconst b = await asy(3);\n"
	+ "\tconst c = await Promise.all([spawn(() => work(2)), spawn(() => work(3))]);\n"
	+ "\treturn a + b + c[0] + c[1];\n}\n"
	+ "console.log(`${await asyncSite()}`);\n");
const asyncStep = routineBody(asyncC, "dollarlifted_asyncSite_");
if (asyncC != "" && asyncStep == "") report("async: the step routine of asyncSite not found in the emitted C");
if (asyncStep != "") {
	const waits = blockingWaits(asyncStep);
	if (waits != 0) report(`async: ${waits} blocking waits in the step routine`);
	const states = resumeStates(asyncStep);
	if (states != SITES) report(`async: ${states} resume states for ${SITES} await sites`);
}

const actorC = emitMain("actor", helpers
	+ "actor Other { get(n: int32): int32 { return n * 2; } }\n"
	+ "actor Counter {\n"
	+ "\ttotal: int32 = 0;\n"
	+ "\tactorSite(o: Other): int32 {\n"
	+ "\t\tconst a = await spawn(() => work(1));\n"
	+ "\t\tconst b = await o.get(3);\n"
	+ "\t\tconst c = await Promise.all([spawn(() => work(2)), spawn(() => work(3))]);\n"
	+ "\t\tthis.total = a + b + c[0] + c[1];\n"
	+ "\t\treturn this.total;\n\t}\n}\n"
	+ "const o = new Other();\nconst k = new Counter();\nconsole.log(`${await k.actorSite(o)}`);\n");
const actorStep = routineBody(actorC, "dollarlifted_Counter_actorSite_");
if (actorC != "" && actorStep == "") report("actor: the step routine of Counter.actorSite not found in the emitted C");
if (actorStep != "") {
	const waits = blockingWaits(actorStep);
	if (waits != 0) report(`actor: ${waits} blocking waits in the step routine`);
	const states = resumeStates(actorStep);
	if (states != SITES) report(`actor: ${states} resume states for ${SITES} await sites`);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
