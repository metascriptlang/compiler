// `securityTxt({...})` puts the `solana-security-txt` block in the program's ELF: the begin marker,
// `key\0value\0` for each field in the order it is written (camelCase to the wire's snake_case), the
// end marker, each followed by a NUL, once and byte for byte, as the `security_txt!` macro of the
// solana-security-txt 1.1.3 crate lays it out. The block is `used, retain`: without `retain` the
// `--gc-sections` link drops it. A value with a quote, a backslash, a newline, a multibyte character
// or a trigraph reaches the ELF unchanged, and the program that declares it still passes `msc test`.
//
// WHY A SUBPROCESS: the observable is the linked `.so`, which no unit test reaches. The compiler under
// test is $MSC, else `./msc`.
//
// RED PRE-FIX: `retain` removed from the emitted attribute: no block in the ELF.
// GREEN POST-FIX: GUARD-OK.

import { execFileResult, ExecFileResult, cwd, exit, env } from "std/process";
import { ensureDir, removeAll, readFile } from "std/fs";

const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSolanaSecurityTxt`;
const fixtures = `${root}/src/test/guard/fixtures`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function run(args: string[]): ExecFileResult {
	return execFileResult(msc, args, root);
}

function text(into: uint8[], s: string): void {
	const bytes = s.asBytes();
	for (let i = 0; i < bytes.length; i++) into.push(bytes[i]);
}

function pair(into: uint8[], key: string, value: uint8[]): void {
	text(into, key);
	into.push(0);
	for (const b of value) into.push(b);
	into.push(0);
}

function str(s: string): uint8[] {
	const bytes: uint8[] = [];
	text(bytes, s);
	return bytes;
}

function block(pairs: uint8[]): uint8[] {
	const bytes: uint8[] = [];
	text(bytes, "=======BEGIN SECURITY.TXT V1=======");
	bytes.push(0);
	for (const b of pairs) bytes.push(b);
	text(bytes, "=======END SECURITY.TXT V1=======");
	bytes.push(0);
	return bytes;
}

function occurrences(file: Readonly<Span<uint8>>, needle: Readonly<Span<uint8>>): number {
	let found = 0;
	for (let at = 0; at + needle.length <= file.length; at++) {
		let same = true;
		for (let i = 0; i < needle.length && same; i++) { same = file[at + i] == needle[i]; }
		if (same) found++;
	}
	return found;
}

function skip(why: string): void {
	console.log(`GUARD-SKIP ${why}`);
	exit(0);
}

function elf(label: string, fixture: string, expected: uint8[]): void {
	const output = `${dir}/${label}.so`;
	const built = run(["build", fixture, "--os=solana", "--release", `--output=${output}`]);
	if (built.exitCode != 0 && (built.output + built.errorOutput).includes("--os=solana requires ")) skip("no SBF toolchain on this host");
	if (built.exitCode != 0) {
		report(`${label}: build failed: ${built.output}${built.errorOutput}`);
		return;
	}
	const read = readFile(output);
	if (!read.ok) {
		report(`${label}: cannot read ${output}`);
		return;
	}
	const file = read.value.asBytes();
	const begin = occurrences(file, str("=======BEGIN SECURITY.TXT V1======="));
	const whole = occurrences(file, expected);
	if (begin != 1 || whole != 1) report(`${label}: the ELF holds ${begin} begin marker(s) and ${whole} copy of the expected ${expected.length}-byte block, want 1 and 1`);
}

removeAll(dir);
ensureDir(dir);

const policy: uint8[] = [];
text(policy, "say ");
policy.push(0x22);
text(policy, "hi");
policy.push(0x22);
policy.push(0x5c);
text(policy, " done");
policy.push(0x0a);
text(policy, "line two ");
policy.push(0xc3);
policy.push(0xa9);
text(policy, "1 ");
policy.push(0xe2);
policy.push(0x9c);
policy.push(0x93);
text(policy, " ??/ ");
policy.push(0x0a);
text(policy, "7");

const all: uint8[] = [];
pair(all, "policy", policy);
pair(all, "name", str("Hibernal"));
pair(all, "source_code", str("https://github.com/example/hibernal"));
pair(all, "contacts", str("email:security@hibernal.example,link:https://hibernal.example/security"));
pair(all, "project_url", str("https://hibernal.example"));
pair(all, "preferred_languages", str("en,vi"));
pair(all, "encryption", str("-----BEGIN PGP PUBLIC KEY BLOCK-----\nabc\n-----END PGP PUBLIC KEY BLOCK-----\n"));
pair(all, "source_revision", str("0123456789abcdef0123456789abcdef01234567"));
pair(all, "source_release", str("v1.0.0"));
pair(all, "auditors", str("None"));
pair(all, "acknowledgements", str(""));
pair(all, "expiry", str("2030-01-01"));
elf("all", `${fixtures}/solanaSecurityTxt.ms`, block(all));

const required: uint8[] = [];
pair(required, "name", str("Bare"));
pair(required, "project_url", str("https://bare.example"));
pair(required, "contacts", str("email:a@bare.example"));
pair(required, "policy", str("none"));
elf("required", `${fixtures}/solanaSecurityTxtRequired.ms`, block(required));

const tested = run(["test", `${fixtures}/solanaSecurityTxt.ms`]);
if (tested.exitCode != 0) report(`host tests of the program that declares securityTxt failed: ${tested.output}${tested.errorOutput}`);

if (failed != 0) exit(1);
console.log("GUARD-OK");
