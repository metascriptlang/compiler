// A real program's hot loop that stores one cell into array slots does its rc work with plain
// loads and stores at --danger: no atomic instruction in the compiled loop function.
// Law: paper/ULTRALOCK.md M3 ("Every rc op is plain except on an Arc/Locked header").
//
// WHY BOTH BUILDS: the ledger build proves the loop calls the rc helpers at least once per
// iteration, so an empty atomic count cannot come from a loop the optimizer emptied.
//
// RED MEANS msIncRef or msDecRefIsLast went back to an atomic read-modify-write, or the
// codegen reached a SHARE helper for a cell that never left its thread. Proven red with
// msIncRef and msDecRefIsLast turned into __atomic_fetch_add/sub: ldaddal in guardHotLoop.

import { execFileResult, cwd, exit, env, platform } from "std/process";
import { removeAll, ensureDir } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardHotLoop`;
const fixture = `${root}/src/test/guard/fixtures/hotLoopRc.ms`;
const iterations = 1000;
const atomicMarks = ["ldadd", "ldclr", "ldset", "ldeor", "swp", "cas", "ldxr", "ldaxr", "stxr", "stlxr", "ldar", "ldapr", "stlr", "lock", "xchg", "xadd", "cmpxchg", "mfence"];

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function loopBody(listing: string): string {
	let out = "";
	let inside = false;
	for (const line of listing.split("\n")) {
		if (line.includes("<_guardHotLoop>:") || line.includes("<guardHotLoop>:")) {
			inside = true;
			continue;
		}
		if (!inside) continue;
		if (line.trim() == "" || line.endsWith(">:")) break;
		out += `${line}\n`;
	}
	return out;
}

function atomicIn(body: string): string {
	for (const line of body.split("\n")) {
		const parts = line.split("\t").map((p: string): string => p.trim()).filter((p: string): boolean => p != "");
		if (parts.length < 2) continue;
		const op = parts[1].split(" ")[0];
		for (const mark of atomicMarks) {
			if (op.startsWith(mark)) return line.trim();
		}
	}
	return "";
}

removeAll(dir);
ensureDir(dir);

const ledger = execFileResult(msc, ["build", fixture, "--passC=-DMS_DRC_LEDGER", `--output=${dir}/ledger`], dir);
if (ledger.exitCode != 0) {
	report(`ledger build failed: ${ledger.output}${ledger.errorOutput}`);
} else {
	const run = execFileResult(`${dir}/ledger`, [], dir);
	const counts = `${run.output}${run.errorOutput}`.split("\n").filter((l: string): boolean => l.startsWith("LEDGER COUNTS "));
	const inc = counts.length == 0 ? -1 : counts[0].split("rc_inc=")[1].split(" ")[0].parseInt();
	if (inc < iterations) report(`the loop made ${inc} rc increments for ${iterations} iterations, so it no longer exercises the rc helpers`);
}

const cc = platform == "darwin" ? ["--cc=clang"] : [];
const danger = execFileResult(msc, ["build", fixture, "--danger", ...cc, `--output=${dir}/danger`], dir);
if (danger.exitCode != 0) {
	report(`danger build failed: ${danger.output}${danger.errorOutput}`);
} else {
	const dis = execFileResult("objdump", ["-d", "--no-show-raw-insn", `${dir}/danger`], dir);
	const body = loopBody(dis.output);
	if (body == "") report("guardHotLoop not found in the --danger binary");
	else if (atomicIn(body) != "") report(`guardHotLoop has an atomic instruction: ${atomicIn(body)}`);
}

if (failed > 0) exit(1);
console.log("GUARD-OK");
