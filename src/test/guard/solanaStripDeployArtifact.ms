// An `--os=solana` program ships the way `cargo build-sbf` ships one: the deploy artifact
// carries no .symtab or .strtab, the unstripped link stays beside it as `<out>.debug`, and
// `--strip` leaves no `.debug` at all. A host build keeps its symbols unless `--strip`.
//
// WHY A SUBPROCESS: the observable is the section table of the linked file, which the
// compiler's own unit tests cannot reach. The compiler under test is $MSC, else `./msc`; the
// sections are read with the platform-tools `llvm-readelf`. A host without the SBF toolchain
// prints GUARD-SKIP, which the runner reports as unscored.
//
// RED PRE-FIX: the `.so` of a default build, and of `--strip`, listed .symtab and .strtab.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, ExecFileResult, cwd, exit, env, findOnPath } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir, readFile } from "std/fs";
import { dirname } from "std/fs/path";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSolanaStrip`;
const program = `${dir}/prog.so`;

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

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/prog.ms`, "import { logU64, instructionData } from \"std/solana\";\nfunction main(): void { logU64(instructionData().length as uint64); }\nmain();\n");
writeFile(`${dir}/hello.ms`, "console.log(\"hi\");\n");

function build(args: string[]): ExecFileResult {
	const all: string[] = ["build"];
	for (const a of args) all.push(a);
	return execFileResult(msc, all, dir);
}

const first = build(["prog.ms", "--os=solana", `--output=${program}`]);
if (first.exitCode != 0 && (first.output + first.errorOutput).includes("--os=solana requires ")) skip("no SBF toolchain on this host");
if (first.exitCode != 0) {
	report(`default build failed: ${first.output}${first.errorOutput}`);
	exit(1);
}

const readelf = readelfBesideToolchain();
if (readelf == "") skip("no llvm-readelf beside the SBF toolchain");

function listing(path: string): string {
	if (!exists(path)) return "";
	return execFileResult(readelf, ["-S", "--wide", path]).output;
}

function names(path: string): string {
	let kept = "";
	for (const name of [".text", ".symtab", ".strtab"]) {
		if (listing(path).includes(` ${name} `)) kept = `${kept}${name} `;
	}
	return kept;
}

function sections(label: string, path: string, want: string): void {
	const got = names(path);
	if (got != want) report(`${label}: sections [${got}] want [${want}]`);
}

sections("default deploy artifact", program, ".text ");
sections("default .debug copy", `${program}.debug`, ".text .symtab .strtab ");

const stripped = build(["prog.ms", "--os=solana", "--strip", `--output=${program}`]);
if (stripped.exitCode != 0) report(`--strip build failed: ${stripped.output}${stripped.errorOutput}`);
sections("--strip deploy artifact", program, ".text ");
if (exists(`${program}.debug`)) report("--strip left a .debug copy");

const again = build(["prog.ms", "--os=solana", `--output=${program}`]);
if (again.exitCode != 0) report(`rebuild without --strip failed: ${again.output}${again.errorOutput}`);
sections("rebuilt deploy artifact", program, ".text ");
sections("rebuilt .debug copy", `${program}.debug`, ".text .symtab .strtab ");

function size(path: string): int64 {
	const r = readFile(exists(`${path}.exe`) ? `${path}.exe` : path);
	return r.ok ? r.value.length as int64 : -1;
}

const hostDefault = build(["hello.ms", "--gc=drc", `--output=${dir}/hostDefault`]);
const hostStripped = build(["hello.ms", "--gc=drc", "--strip", `--output=${dir}/hostStripped`]);
if (hostDefault.exitCode != 0 || hostStripped.exitCode != 0) {
	report(`host build failed: ${hostDefault.errorOutput}${hostStripped.errorOutput}`);
} else if (size(`${dir}/hostStripped`) >= size(`${dir}/hostDefault`)) {
	report(`a host build with --strip is not smaller: ${size(`${dir}/hostStripped`)} vs ${size(`${dir}/hostDefault`)}`);
}

if (failed != 0) exit(1);
console.log("GUARD-OK");
