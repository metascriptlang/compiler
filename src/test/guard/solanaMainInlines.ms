// MsMain is emitted without `noinline` under --os=solana, so a --release build folds it into
// `entrypoint`. When that fold overflows the 4,096-byte SBF frame (the entry's account table plus
// the program's own locals), the build says so on stderr and rebuilds the dispatcher with MsMain
// out of line, which keeps the program buildable. A frame that overflows either way still fails.
//
// WHY A SUBPROCESS: the observable is the symbol table of the linked program and the compiler's
// stderr, which only the SBF toolchain produces. The compiler under test is $MSC, else `./msc`.
// A host without the SBF toolchain prints GUARD-SKIP, which the runner reports as unscored.
//
// RED MEANS: MsMain stays out of line in a program that fits (the `noinline` came back), the
// fallback does not announce itself, or the program that needs the fallback does not build.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, findOnPath } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir } from "std/fs";
import { dirname } from "std/fs/path";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSolanaMainInlines`;
const NOTE = "rebuilding MsMain out of line";

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

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

const small = `
import { instructionData, logU64 } from "std/solana";

function main(): void {
	logU64(instructionData().length as uint64);
}

main();
`;

const big = `
import { instructionData, logU64 } from "std/solana";

struct Big {
	words: uint64[350];
}

function spread(seed: uint64, at: uint64): uint64 {
	let big: Big = { words: [] };
	for (let index: uint64 = 0; index < 350; index++) {
		big.words[index] = seed * index;
	}
	return big.words[at % 350];
}

function main(): void {
	const length = instructionData().length;
	logU64(spread(length, length * 7));
}

main();
`;

removeAll(dir);
ensureDir(dir);
const readelf = readelfBesideToolchain();

function build(name: string, source: string, flag: string): { ok: boolean, stderr: string, hasMsMain: boolean } {
	writeFile(`${dir}/${name}.ms`, source);
	const out = `${dir}/${name}.so`;
	const built = execFileResult(msc, ["build", `${name}.ms`, "--os=solana", flag, `--output=${out}`], dir);
	const log = built.output + built.errorOutput;
	if (built.exitCode != 0 && log.includes("--os=solana requires ")) skip("no SBF toolchain on this host");
	if (readelf == "") skip("no llvm-readelf beside the SBF toolchain");
	let hasMsMain = false;
	if (built.exitCode == 0) {
		for (const line of execFileResult(readelf, ["-s", "--wide", `${out}.debug`]).output.split("\n")) {
			if (line.endsWith(" MsMain") && line.includes(" FUNC ")) hasMsMain = true;
		}
	}
	return { ok: built.exitCode == 0, stderr: log, hasMsMain };
}

const fits = build("small", small, "--release");
if (!fits.ok) report(`a small program did not build: ${fits.stderr}`);
if (fits.hasMsMain) report("a program that fits keeps MsMain out of line under --release");
if (fits.stderr.includes(NOTE)) report("a program that fits announced the out-of-line fallback");

const folded = build("big", big, "--release");
if (!folded.ok) report(`the program whose entry overflows when MsMain is folded did not build: ${folded.stderr}`);
if (folded.ok && !folded.stderr.includes(NOTE)) report("the fold overflowed and the build did not say that it rebuilt MsMain out of line");
if (folded.ok && !folded.hasMsMain) report("the fallback build has no out-of-line MsMain");

const unfolded = build("bigDebug", big, "--lto=off");
if (!unfolded.ok) report(`the same program without LTO did not build: ${unfolded.stderr}`);
if (unfolded.stderr.includes(NOTE)) report("a build without LTO announced the fallback it cannot need");

if (failed != 0) exit(1);
console.log("GUARD-OK");
