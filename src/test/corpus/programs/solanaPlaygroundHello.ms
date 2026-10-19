// @stdout: ✓ alice creates the counter: ok
// @stdout: counter.value = 42 · 24 bytes
// @skip-raiser: std/solana has memory and kernel modules for C and JS only
// note: the geass playground's hello program; the Solana program and its host simulator print the same lines on C and JS. Its enums drop `export`: a JS bundle exports no enum.

import {
	Discriminator, Program, ProgramError, Pubkey, System, SYSTEM_PROGRAM_ID, Writable,
	WritableSigner, accountDiscriminator, accounts, createPda, failWith, findProgramAddressOf,
	instruction, instructionDiscriminator,
} from "std/solana";
import { HostAccount, run } from "std/solana/host";

export struct Counter {
	value: uint64;
	bump: uint8;
	pad: uint8[7];
}

export function discriminator(this typeof Counter): Discriminator {
	return @comptime { return accountDiscriminator("Counter"); };
}

export struct InitAccounts {
	payer: WritableSigner;
	counter: Writable;
	systemProgram: Program<System>;
}

function init(): Result<uint64, ProgramError> {
	const x = try accounts<InitAccounts>();
	const made = try createPda<Counter>(x.payer, x.counter, ["counter"]);
	const counter = made.asMutable().data();
	counter.value = 42;
	counter.bump = made.foundBump();
	return Result.ok(0);
}

enum HelloOp {
	Init,
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<HelloOp>()) {
		HelloOp.Init => init(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

function keyOf(seed: uint8): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = seed;
	return key;
}

function holder(key: Pubkey, lamports: uint64, signer: boolean): HostAccount {
	return {
		key: key, owner: SYSTEM_PROGRAM_ID, lamports: lamports, data: [],
		signer: signer, writable: true, executable: false,
	};
}

function sent(program: Pubkey, payer: HostAccount, counter: Pubkey): HostAccount[] {
	const system = {
		...holder(SYSTEM_PROGRAM_ID, 1, false),
		owner: Pubkey.zero(), writable: false, executable: true,
	};
	return [payer, holder(counter, 0, false), system];
}

function call(name: string): uint8[] {
	const tag = instructionDiscriminator(name);
	const bytes: uint8[] = [];
	for (let i = 0; i < 8; i++) { bytes.push(tag.bytes[i]); }
	return bytes;
}

function nameOf(code: uint64): string {
	if (code == 3010) { return "AccountNotSigner (3010)"; }
	if (code == 2006) { return "ConstraintSeeds (2006)"; }
	return `error ${code}`;
}

function report(label: string, result: uint64, counter: HostAccount): void {
	const mark = result == 0 ? "✓" : "✗";
	const outcome = result == 0 ? "ok" : `refused by the program, ${nameOf(result)}`;
	console.log(`${mark} ${label}: ${outcome}`);
	if (counter.data.length > 0) {
		console.log(`    counter.value = ${counter.data[8]} · ${counter.data.length} bytes`);
	}
}

const program = keyOf(9);
const alice = keyOf(1);
const address = findProgramAddressOf(program, ["counter"]);

if (address.ok) {
	console.log(`counter lives at ${address.value.key.toBase58()}`);

	const unsigned = sent(program, holder(alice, 10000000000, false), address.value.key);
	const refused = run(program, unsigned, call("Init"), entry).result;
	report("init without alice's signature", refused, unsigned[1]);

	const elsewhere = sent(program, holder(alice, 10000000000, true), keyOf(7));
	const misplaced = run(program, elsewhere, call("Init"), entry).result;
	report("init at an address off the seeds", misplaced, elsewhere[1]);

	const created = sent(program, holder(alice, 10000000000, true), address.value.key);
	report("alice creates the counter", run(program, created, call("Init"), entry).result, created[1]);
}
