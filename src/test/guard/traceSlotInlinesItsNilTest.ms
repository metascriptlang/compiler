// A generated trace hook tests each slot for nil and pushes the edge in its own body; the only
// call it keeps is the out-of-line growth of the trace stack (msCellSeqGrow), so the collector's
// per-slot work is no call at all.
// Reference: the trace-ref hook is inline and tests the slot before touching the environment
// (lib/system/orc.nim:140-147); its stack push is inline with an out-of-line resize
// (lib/system/cellseqs_v2.nim:19-31).
//
// WHY MACHINE CODE: the emitted C reads the same whether msOrcTraceRef is inline or an extern
// call made once per slot, nil slots included. fixtures/traceSlotShapes.ms has the three slot
// shapes a trace hook walks (a class field, a ref-array element loop, a closure env); it is
// built with $MSC at --danger and at --release, and every trace hook in the binary is read with
// `objdump -d`.
//
// RED MEANS a trace hook calls msOrcTraceRef (or anything but the stack growth) again: the
// runtime/drc.h helper went out of line. Compiler under test: $MSC, else `./msc`.

import { execFileResult, cwd, exit, env } from "std/process";
import { removeAll, ensureDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardTraceSlot`;
const shapes = ["Node__", "msRefArray_", "dollarEnv_"];

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function symbolOf(line: string): string {
	const open = line.indexOf("<");
	const close = line.indexOf(">", open);
	if (open < 0 || close < 0) return "";
	let name = line.substring(open + 1, close);
	const plus = name.indexOf("+");
	if (plus >= 0) name = name.substring(0, plus);
	return name.startsWith("_") ? name.substring(1) : name;
}

function isCall(line: string): boolean {
	const words = line.split("\t").join(" ").split(" ").filter((w: string): boolean => w != "");
	for (const w of words) {
		if (w == "bl" || w == "b" || w == "call" || w == "callq" || w == "jmp" || w == "jmpq") return true;
	}
	return false;
}

function checkBinary(mode: string): void {
	const bin = `${dir}/shapes-${mode}`;
	const built = execFileResult(msc, ["build", `${root}/src/test/guard/fixtures/traceSlotShapes.ms`, `--${mode}`, `--output=${bin}`], dir);
	if (built.exitCode != 0) {
		report(`${mode}: build failed: ${built.output}${built.errorOutput}`);
		return;
	}
	const listing = execFileResult("objdump", ["-d", "--no-show-raw-insn", bin], dir);
	if (listing.exitCode != 0) {
		report(`${mode}: objdump failed: ${listing.errorOutput}`);
		return;
	}
	const seen: string[] = [];
	let fn = "";
	for (const line of listing.output.split("\n")) {
		const t = line.trim();
		if (t.endsWith(">:")) {
			fn = symbolOf(t);
			continue;
		}
		if (t.includes("msOrcTraceRef")) report(`${mode}: ${fn} still references msOrcTraceRef: ${t}`);
		if (!fn.endsWith("Trace")) continue;
		for (const shape of shapes) {
			if (fn.startsWith(shape) && !seen.includes(shape)) seen.push(shape);
		}
		if (!isCall(t)) continue;
		const callee = symbolOf(t);
		if (callee == fn || callee == "msCellSeqGrow" || callee.endsWith("Trace")) continue;
		report(`${mode}: trace hook ${fn} calls ${callee}: ${t}`);
	}
	for (const shape of shapes) {
		if (!seen.includes(shape)) report(`${mode}: no ${shape}* trace hook found in the binary`);
	}
}

removeAll(dir);
ensureDir(dir);
checkBinary("danger");
checkBinary("release");

if (failed > 0) exit(1);
console.log("GUARD-OK");
