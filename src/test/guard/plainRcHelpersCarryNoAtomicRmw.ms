// An rc operation on a header nothing shares is a plain load and store; only the SHARE helpers
// (msAtomicIncRef, msAtomicDecRefIsLast) keep a read-modify-write, and the collector's colour and count code (msOrcCollect) is plain.
// Law: paper/ULTRALOCK.md M3 ("Every rc op is plain except on an Arc/Locked header").
//
// WHY MACHINE CODE: `rc` is `_Atomic`, so `+=` and `fetch_sub` on it compile to a seq_cst RMW
// (ldaddal on arm64, lock add on x86-64) while the C reads as plain; the emitted-name guards
// (refArrayElementFamily) cannot see that. The fixture's helper bodies are compiled with
// `clang -O2 -S` (with runtime/drc.c for msOrcCollect) for the host and for x86-64 and scanned for atomic instructions.
//
// RED MEANS an owner helper in runtime/drc.h went back to `+=`, `-=`, `|=`, `atomic_fetch_*` or a
// seq_cst store on `rc`, or a SHARE helper lost its RMW. Compiler under test: $MSC, else `./msc`;
// the runtime read is the one beside it.

import { execFileResult, cwd, exit, env, platform } from "std/process";
import { removeAll, ensureDir, readFile, exists } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const mscDir = msc.substring(0, msc.lastIndexOf("/"));
const runtimeRoot = mscDir != "" && exists(`${mscDir}/runtime/drc.h`) ? mscDir : root;
const dir = `${root}/out/guardPlainRc`;
const owners = ["rcPinOwnerInc", "rcPinOwnerDec", "rcPinOwnerOrcInc", "rcPinOwnerOrcDec", "rcPinOwnerMark", "rcPinIsAscii"];
const shares = ["rcPinShareInc", "rcPinShareDec"];
const sdk = platform == "darwin" ? execFileResult("xcrun", ["--show-sdk-path"], root).output.trim() : "";
const targets = sdk == "" ? [["host", ""]] : [["host", ""], ["x86_64", `--target=x86_64-linux-gnu -isystem ${sdk}/usr/include`]];
const atomicMarks = ["ldadd", "ldclr", "ldset", "ldeor", "swp", "ldaxr", "ldxr", "stlxr", "stxr", "stlr", "cas", "ldar", "dmb", "lock", "xchg", "xadd", "cmpxchg", "mfence"];

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function body(listing: string, name: string): string {
	let out = "";
	let inside = false;
	for (const line of listing.split("\n")) {
		const t = line.trim();
		if (t.startsWith(`_${name}:`) || t.startsWith(`${name}:`)) {
			inside = true;
			continue;
		}
		if (!inside) continue;
		if (t.startsWith(".cfi_endproc") || t.startsWith(".size")) break;
		if (!t.startsWith(".") && !t.startsWith(";") && !t.startsWith("#")) out += `${t}\n`;
	}
	return out;
}

function atomicIn(text: string): string {
	for (const line of text.split("\n")) {
		for (const mark of atomicMarks) {
			if (line.startsWith(mark)) return line;
		}
	}
	return "";
}
function listingOf(cell: string, label: string, flag: string, source: string, name: string): string {
	const args = ["-O2", "-std=c11", "-S", `-I${runtimeRoot}`, `-I${runtimeRoot}/runtime`, source, "-o", `${cell}/${name}.s`];
	if (flag != "") for (const f of flag.split(" ")) args.push(f);
	const built = execFileResult("clang", args, cell);
	if (built.exitCode != 0) {
		report(`${label}: clang failed on ${name}: ${built.output}${built.errorOutput}`);
		return "";
	}
	const read = readFile(`${cell}/${name}.s`);
	return read.ok ? read.value : "";
}

for (const [label, flag] of targets) {
	const cell = `${dir}/${label}`;
	removeAll(cell);
	ensureDir(cell);
	const helpers = listingOf(cell, label, flag, `${root}/src/test/guard/fixtures/rcHelperShapes.c`, "shapes");
	for (const name of owners) {
		const text = body(helpers, name);
		if (text == "") report(`${label}: ${name} not found in the assembly`);
		else if (atomicIn(text) != "") report(`${label}: ${name} has an atomic instruction: ${atomicIn(text)}`);
	}
	for (const name of shares) {
		const text = body(helpers, name);
		if (text == "") report(`${label}: ${name} not found in the assembly`);
		else if (atomicIn(text) == "") report(`${label}: ${name} lost its read-modify-write`);
	}
	if (flag == "") {
		const collector = body(listingOf(cell, label, flag, `${runtimeRoot}/runtime/drc.c`, "drc"), "msOrcCollect");
		if (collector == "") report(`${label}: msOrcCollect not found in the assembly`);
		else if (atomicIn(collector) != "") report(`${label}: msOrcCollect has an atomic instruction: ${atomicIn(collector)}`);
	}
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
