// A generic std/solana function costs one thin wrapper per account type, not one body: the checks
// live in shared cores that take the type's constants (discriminator word, size), and the wrapper
// only passes them and keeps the typed result. This builds a program that instantiates every
// generic for nine account types and reads each copy's size from the `.debug` copy's symbol table.
//
// WHY A SUBPROCESS: the observable is the size of linked functions, which only the SBF toolchain
// produces. The compiler under test is $MSC, else `./msc`; the symbols are read with the
// platform-tools `llvm-readelf`. A host without the SBF toolchain prints GUARD-SKIP, which the
// runner reports as unscored.
//
// RED MEANS: a wrapper grew past its bound (a check moved back into the generic body, or the body
// of a shared core was inlined into the wrappers), a family lost its copies, the input parser is
// inlined into more than one function, or dispatch pulled in a signed division.
// RED PRE-FIX: createPdaOf 920 bytes a copy, realloc 824, close 752, verifiedPda 512 and 520,
// selectInstruction 688, ownProgram 600, __divdi3 linked. GREEN POST-FIX: GUARD-OK.

import { execFileResult, cwd, exit, env, findOnPath } from "std/process";
import { writeFile, ensureDir, removeAll, exists, readDir } from "std/fs";
import { dirname } from "std/fs/path";

const TYPES = 9;
const root = cwd();
const mscEnv = env.get("MSC");
const msc = mscEnv != "" ? mscEnv : `${root}/msc`;
const dir = `${root}/out/guardSolanaGenericSize`;
const program = `${dir}/probe.so`;

let failed = 0;

function report(msg: string): void {
	console.log(`GUARD-FAIL ${msg}`);
	failed = failed + 1;
}

function skip(why: string): void {
	console.log(`GUARD-SKIP ${why}`);
	exit(0);
}

function toolBesideToolchain(tool: string): string {
	const dirs: string[] = [];
	const clang = env.get("MSC_SBF_CLANG");
	if (clang != "") dirs.push(dirname(clang));
	const home = env.get("HOME");
	if (home != "" && exists(`${home}/.cache/solana`)) {
		for (const entry of readDir(`${home}/.cache/solana`)) dirs.push(`${home}/.cache/solana/${entry}platform-tools/llvm/bin`);
	}
	for (const d of dirs) {
		if (exists(`${d}/${tool}`)) return `${d}/${tool}`;
		if (exists(`${d}/${tool}.exe`)) return `${d}/${tool}.exe`;
	}
	return findOnPath(tool);
}

function fieldsOf(line: string): string[] {
	const out: string[] = [];
	for (const part of line.split(" ")) {
		const word = part.trim();
		if (word != "") out.push(word);
	}
	return out;
}

function hex(text: string): int32 {
	let value = 0;
	for (let i = 0; i < text.length; i++) {
		const digit = "0123456789abcdef".indexOf(text.slice(i, i + 1));
		value = value * 16 + digit;
	}
	return value;
}

function typeSource(i: number): string {
	const fields = [
		"seed: uint64;\n\towner: Pubkey;\n\tpoints: uint64;\n\tbump: uint8;",
		"owner: Pubkey;\n\tmint: Pubkey;\n\tamount: uint64;\n\tbump: uint8;",
		"a: uint64;\n\tb: uint64;\n\tc: uint64;\n\td: uint64;\n\tbump: uint8;",
		"owner: Pubkey;\n\tbump: uint8;",
		"seed: uint64;\n\tx: Pubkey;\n\ty: Pubkey;\n\tz: Pubkey;\n\tbump: uint8;",
		"count: uint32;\n\tlevel: uint32;\n\towner: Pubkey;\n\tbump: uint8;",
		"owner: Pubkey;\n\tbig: uint8[96];\n\tbump: uint8;",
		"score: uint64;\n\towner: Pubkey;\n\tbump: uint8;",
		"a: Pubkey;\n\tb: Pubkey;\n\tn: uint64;\n\tbump: uint8;",
	];
	return `
export struct Pet${i} {
	${fields[i % fields.length]}
}

export function discriminator(this typeof Pet${i}): Discriminator {
	return @comptime { return accountDiscriminator("Pet${i}"); };
}

export struct Args${i} {
	seed: uint64;
	bump: uint8;
}

export struct Accounts${i} {
	payer: WritableSigner;
	target: Writable;
	pet: Mutable<Pet${i}>;
	peek: Owned<Pet${i}>;
	rolled: Delegated<Pet${i}>;
	fresh: Writable;
}

function run${i}(): Result<uint64, ProgramError> {
	const a = try args<Args${i}>();
	const x = try accounts<Accounts${i}>();
	const made = try createPda<Pet${i}>(x.payer, x.target, ["pet${i}", x.payer, leBytes(a.seed)]);
	const _fresh = try create<Pet${i}>(x.payer, x.fresh);
	const _checked = try pdaWithBump(x.pet, ["pet${i}", x.payer, leBytes(a.seed)], a.bump);
	const _found = try pda(x.pet, ["pet${i}", x.payer]);
	const _rolledBump = try pdaWithBump(x.rolled, ["pet${i}", x.payer], a.bump);
	const _rolledFound = try pda(x.rolled, ["pet${i}", x.payer]);
	const _grown = try realloc<Pet${i}>(x.pet, 200, x.payer);
	const direct = try mutable<Pet${i}>(6);
	const seen = try owned<Pet${i}>(7);
	const rolled = try delegated<Pet${i}>(8);
	const _closed = try close(x.pet, x.payer.asWritable());
	return Result.ok(made.account.data().bump as uint64 + direct.data().bump as uint64 +
		seen.data().bump as uint64 + rolled.data().bump as uint64);
}
`;
}

function probeSource(): string {
	let source = `import {
	Delegated,
	Discriminator,
	Mutable,
	Owned,
	ProgramError,
	Pubkey,
	Writable,
	WritableSigner,
	accountDiscriminator,
	accounts,
	args,
	close,
	create,
	createPda,
	delegated,
	failWith,
	instruction,
	leBytes,
	mutable,
	owned,
	pda,
	pdaWithBump,
	realloc,
	external,
	externalMutable,
} from "std/solana";
import { Mint, TokenAccount } from "std/solana/token";

export enum ProbeOp {
`;
	for (let i = 0; i < TYPES; i++) source = `${source}\tRun${i},\n`;
	source = `${source}\tExternals,\n}\n`;
	for (let i = 0; i < TYPES; i++) source = `${source}${typeSource(i)}`;
	source = `${source}
function externals(): Result<uint64, ProgramError> {
	const mint = try external<Mint>(0);
	const held = try external<TokenAccount>(1);
	const claimed = try externalMutable<TokenAccount>(2);
	const spent = try externalMutable<Mint>(3);
	const a = try mint.read();
	const b = try held.read();
	const c = try claimed.read();
	const d = try spent.read();
	return Result.ok(a.decimals as uint64 + b.amount + c.amount + d.decimals as uint64);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<ProbeOp>()) {
`;
	for (let i = 0; i < TYPES; i++) source = `${source}\t\tProbeOp.Run${i} => run${i}(),\n`;
	return `${source}\t\tProbeOp.Externals => externals(),
	};
}

function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
entry();
`;
}

// One bound per generic family, in bytes per copy of the linked wrapper, and the number of copies
// the probe makes. A pass-through wrapper (the result type does not depend on the account type)
// is a call and a return; one that keeps a typed result also rebuilds the result.
struct Bound {
	family: string;
	copies: int32;
	most: int32;
}

const BOUNDS: Bound[] = [
	{ family: "close", copies: TYPES, most: 144 },
	{ family: "realloc", copies: TYPES, most: 144 },
	{ family: "Delegated_verifiedPda", copies: TYPES, most: 144 },
	{ family: "Delegated_verifiedPdaWithBump", copies: TYPES, most: 144 },
	{ family: "owned", copies: TYPES, most: 224 },
	{ family: "mutable", copies: TYPES, most: 224 },
	{ family: "delegated", copies: TYPES, most: 224 },
	{ family: "create", copies: TYPES, most: 256 },
	{ family: "Mutable_verifiedPda", copies: TYPES, most: 256 },
	{ family: "Mutable_verifiedPdaWithBump", copies: TYPES, most: 256 },
	{ family: "createPdaOf", copies: TYPES, most: 352 },
	{ family: "readArgs", copies: TYPES * 2, most: 288 },
	{ family: "selectInstruction", copies: 1, most: 224 },
	{ family: "External_read", copies: 2, most: 192 },
	{ family: "ExternalMutable_read", copies: 2, most: 192 },
	{ family: "external", copies: 2, most: 448 },
	{ family: "externalMutable", copies: 2, most: 544 },
];

// The input parser is one shared function: nothing else may carry it.
const ONE_COPY: Bound[] = [
	{ family: "ownProgram", copies: 1, most: 160 },
	{ family: "instructionData", copies: 0, most: 160 },
	{ family: "account", copies: 0, most: 256 },
];

const TEXT_MOST = 90000;

removeAll(dir);
ensureDir(dir);
writeFile(`${dir}/probe.ms`, probeSource());

const built = execFileResult(msc, ["build", "probe.ms", "--os=solana", `--output=${program}`], dir);
if (built.exitCode != 0 && (built.output + built.errorOutput).includes("--os=solana requires ")) skip("no SBF toolchain on this host");
if (built.exitCode != 0) {
	report(`the probe did not build: ${built.output}${built.errorOutput}`);
	exit(1);
}

const readelf = toolBesideToolchain("llvm-readelf");
if (readelf == "") skip("no llvm-readelf beside the SBF toolchain");

const symbols = execFileResult(readelf, ["-s", "--wide", `${program}.debug`]).output;
const sections = execFileResult(readelf, ["-S", "--wide", `${program}.debug`]).output;

let textSize = 0;
for (const line of sections.split("\n")) {
	const fields = fieldsOf(line);
	const at = fields.indexOf(".text");
	if (at >= 0 && fields.length > at + 4) textSize = hex(fields[at + 4]);
}

function nameOf(name: string): string {
	const cut = name.indexOf("__Z");
	return cut < 0 ? name : name.slice(0, cut);
}

function familyOf(name: string): string {
	const base = nameOf(name);
	const cut = base.indexOf("_1");
	return cut < 0 ? base : base.slice(0, cut);
}

const sizes = new Map<string, int32[]>();
for (const line of symbols.split("\n")) {
	const fields = fieldsOf(line);
	if (fields.length < 8 || fields[3] != "FUNC") continue;
	const name = fields[7];
	const generic = nameOf(name).indexOf("_1") >= 0;
	const key = generic ? `generic ${familyOf(name)}` : `plain ${nameOf(name)}`;
	const list = sizes.get(key) ?? [];
	list.push(fields[2].parseInt() as int32);
	sizes.set(key, list);
}

function largest(list: int32[]): int32 {
	let most = 0;
	for (const size of list) if (size > most) most = size;
	return most;
}

for (const bound of BOUNDS) {
	const list = sizes.get(`generic ${bound.family}`) ?? [];
	console.log(`GUARD-INFO ${bound.family}: ${list.length} copies, largest ${largest(list)} bytes (bound ${bound.most})`);
	if (list.length != bound.copies) report(`${bound.family}: ${list.length} copies, want ${bound.copies}`);
	if (largest(list) > bound.most) report(`${bound.family}: a copy is ${largest(list)} bytes, bound ${bound.most}`);
}

for (const bound of ONE_COPY) {
	const list = sizes.get(`plain ${bound.family}`) ?? [];
	console.log(`GUARD-INFO ${bound.family}: ${list.length} copies, largest ${largest(list)} bytes (bound ${bound.most})`);
	if (list.length > 1) report(`${bound.family}: ${list.length} copies, want at most one`);
	if (largest(list) > bound.most) report(`${bound.family}: ${largest(list)} bytes, bound ${bound.most}: the input parser is inlined into it`);
}

if (sizes.has("plain __divdi3")) report("__divdi3 is linked: a signed division of two int32 or int64 values reached the program");

console.log(`GUARD-INFO .text: ${textSize} bytes (bound ${TEXT_MOST})`);
if (textSize == 0) report("the .text size was not read from the section table");
if (textSize > TEXT_MOST) report(`.text is ${textSize} bytes, bound ${TEXT_MOST}`);

if (failed != 0) exit(1);
console.log("GUARD-OK");
