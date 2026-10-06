// `@seeds` of literal seeds with a bare `@bump` checks one address folded at compile time
// against the declared program id, as Anchor v2 folds `seeds = [b"…"], bump` (lang-v2 derive
// parse.rs `emit_seeds_check`, pda.rs `precompute_pda`): the deployed program derives nothing.
// A stored bump (`@bump(account.field)`) and a build without a programId keep the run-time
// derivation, as Anchor's `bump = expr` and an undiscoverable `declare_id!` do.
//
// WHY A SUBPROCESS: the observable is which syscalls the linked SBF program calls, which no
// unit test reaches. A static syscall is `call imm` with src 0 and imm = murmur3 of its name:
// sol_sha256 0x11f49d86, sol_curve_validate_point 0xaa2607ca. The host tests of the fixture
// pin that the folded address accepts the canonical account and refuses others. The compiler
// under test is $MSC, else `./msc`.
//
// RED PRE-FIX: the folded build called sol_sha256 and sol_curve_validate_point; before the
// macro wire carried intVal, the byte-list seed folded as [0, 0] and the host tests failed.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, ExecFileResult, cwd, exit, env } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSolanaSeedsFolded`;
const fixture = `${root}/src/test/guard/fixtures/solanaSeedsFolded.ms`;
const declared = "-d:programId=B7ihZyoXZ1fwAY3TugkiFJ6SXkzJwMuQrxrekBaSmn32";
const SHA256: uint8[8] = [0x85, 0, 0, 0, 0x86, 0x9d, 0xf4, 0x11];
const CURVE: uint8[8] = [0x85, 0, 0, 0, 0xca, 0x07, 0x26, 0xaa];

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function skip(why: string): void {
	console.log(`GUARD-SKIP ${why}`);
	exit(0);
}

function run(args: string[]): ExecFileResult {
	return execFileResult(msc, args, root);
}

function calls(path: string, instruction: Readonly<Span<uint8>>): boolean {
	const read = readFile(path);
	if (!read.ok) return false;
	const bytes = read.value.asBytes();
	for (let at = 0; at + 8 <= bytes.length; at++) {
		let same = true;
		for (let i = 0; i < 8 && same; i++) { same = bytes[at + i] == instruction[i]; }
		if (same) return true;
	}
	return false;
}

function program(label: string, source: string, defines: string[], derives: boolean): void {
	const output = `${dir}/${label}.so`;
	const args: string[] = ["build"];
	for (const d of defines) args.push(d);
	args.push(source);
	args.push("--os=solana");
	args.push(`--output=${output}`);
	const built = run(args);
	if (built.exitCode != 0 && (built.output + built.errorOutput).includes("--os=solana requires ")) skip("no SBF toolchain on this host");
	if (built.exitCode != 0) {
		report(`${label}: build failed: ${built.output}${built.errorOutput}`);
		return;
	}
	const sha = calls(output, SHA256);
	const curve = calls(output, CURVE);
	if (derives && (!sha || !curve)) report(`${label}: expected the run-time derivation, sol_sha256 ${sha}, sol_curve_validate_point ${curve}`);
	if (!derives && (sha || curve)) report(`${label}: expected a folded address, but calls sol_sha256 ${sha}, sol_curve_validate_point ${curve}`);
}

removeAll(dir);
ensureDir(dir);
const text = readFile(fixture);
if (!text.ok) {
	report(`cannot read ${fixture}`);
	exit(1);
}
const stored = `${dir}/storedBump.ms`;
writeFile(stored, text.value.replace("@seeds(\"counter\", [7, 9]) @bump counter", "@seeds(\"counter\", [7, 9]) @bump(counter.bump) counter"));

program("folded", fixture, [declared], false);
program("undeclared", fixture, [], true);
program("storedBump", stored, [declared], true);

const tested = run(["test", declared, fixture]);
if (tested.exitCode != 0) report(`host tests of the folded seeds failed: ${tested.output}${tested.errorOutput}`);

if (failed != 0) exit(1);
console.log("GUARD-OK");
