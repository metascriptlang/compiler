// A --release build for SBF merges its bitcode into one module before the link, and the merge
// must internalize every function except `entrypoint`: a hidden function the merge leaves
// external keeps an out-of-line copy and every call to it opaque to the interprocedural passes,
// so the same program is larger and runs more compute units. This builds a program under
// `--release` and under `--lto=full` alone (the two ways into the merge) and reads the
// merged object `<out>.lto.o` with the platform-tools `llvm-readelf`; the only defined symbols
// that may be non-local are `entrypoint` and `abort` (the one function the backend itself
// calls to lower a trap).
//
// WHY A SUBPROCESS: the observable is the symbol table of the merge's own object, which only the
// SBF toolchain produces. The compiler under test is $MSC, else `./msc`. A host without the SBF
// toolchain prints GUARD-SKIP, which the runner reports as unscored.
//
// RED MEANS: the merge keeps functions external again (an `ld.lld -r` merge listed 224 of them
// for this program), or a function other than `entrypoint` and `abort` is exported
// from the merged module. GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, findOnPath } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir } from "std/fs";
import { dirname } from "std/fs/path";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSolanaLtoInternalizes`;

function skip(why: string): void {
	console.log(`GUARD-SKIP ${why}`);
	exit(0);
}

function readelfBesideToolchain(): string {
	const dirs: string[] = [];
	const clang = env.get("MSC_SBF_CLANG");
	if (clang != "") dirs.push(dirname(clang));
	const home = env.get("HOME");
	if (home != "" && exists(`${home}/.cache/solana`)) {
		for (const entry of readDir(`${home}/.cache/solana`)) dirs.push(`${home}/.cache/solana/${entry}platform-tools/llvm/bin`);
	}
	for (const d of dirs) {
		if (exists(`${d}/llvm-readelf`)) return `${d}/llvm-readelf`;
		if (exists(`${d}/llvm-readelf.exe`)) return `${d}/llvm-readelf.exe`;
	}
	return findOnPath("llvm-readelf");
}

const source = `
import { instructionData, logU64 } from "std/solana";

function scaled(value: int64, divisor: int64): int64 {
	return value / divisor + value % 8;
}

function main(): void {
	const length = instructionData().length as int64;
	logU64(scaled(length * 1000 - 7, length + 3) as uint64);
}

main();
`;

const readelf = readelfBesideToolchain();

function exportedFunctions(flag: string): string[] {
	const name = flag.slice(2);
	const out = `${dir}/${name}.so`;
	const built = execFileResult(msc, ["build", "probe.ms", "--os=solana", flag, `--output=${out}`], dir);
	if (built.exitCode != 0 && (built.output + built.errorOutput).includes("--os=solana requires ")) skip("no SBF toolchain on this host");
	if (built.exitCode != 0) {
		console.log(`GUARD-FAIL ${name}: the probe did not build: ${built.output}${built.errorOutput}`);
		exit(1);
	}
	if (readelf == "") skip("no llvm-readelf beside the SBF toolchain");
	const merged = `${out}.lto.o`;
	if (!exists(merged)) {
		console.log(`GUARD-FAIL ${name}: the merge left no ${merged}: the build did not take LTO`);
		exit(1);
	}
	const exported: string[] = [];
	let functions = 0;
	for (const line of execFileResult(readelf, ["-s", "--wide", merged]).output.split("\n")) {
		const fields: string[] = [];
		for (const part of line.split(" ")) {
			if (part.trim() != "") fields.push(part.trim());
		}
		if (fields.length < 8 || fields[3] != "FUNC") continue;
		functions = functions + 1;
		if (fields[4] != "LOCAL") exported.push(fields[7]);
	}
	console.log(`GUARD-INFO ${name}: ${functions} functions, ${exported.length} non-local: ${exported.join(", ")}`);
	if (functions == 0) {
		console.log(`GUARD-FAIL ${name}: no function was read from the merged module's symbol table`);
		exit(1);
	}
	return exported;
}

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/probe.ms`, source);

let failed = 0;
for (const flag of ["--release", "--lto=full"]) {
	const name = flag.slice(2);
	const exported = exportedFunctions(flag);
	for (const symbol of exported) {
		if (symbol != "entrypoint" && symbol != "abort") {
			console.log(`GUARD-FAIL ${name}: ${symbol} is external in the merged module: the merge did not internalize it`);
			failed = failed + 1;
		}
	}
	if (!exported.includes("entrypoint")) {
		console.log(`GUARD-FAIL ${name}: entrypoint is not defined in the merged module`);
		failed = failed + 1;
	}
}
if (failed != 0) exit(1);
console.log("GUARD-OK");
