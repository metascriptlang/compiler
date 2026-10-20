// @stdout: ✓ alice increments again: ok
// @stdout: ✗ mallory increments alice's counter: refused by the program, error 6000
// @skip-raiser: std/solana has memory and kernel modules for C and JS only
// note: the geass playground's counter program; the Solana program and its host simulator print the same lines on C and JS. Its enums drop `export`: a JS bundle exports no enum.

// A counter stored in a program-derived account.
// init creates the account through a System CPI; increment needs the
// authority that created it. Change a check and press Run.

import {
	Discriminator, Mutable, Program, ProgramError, Pubkey, Signer, System, SYSTEM_PROGRAM_ID,
	Writable, WritableSigner, accountDiscriminator, accounts, bump, createPda, failWith,
	findProgramAddressOf, instruction, instructionDiscriminator, seeds,
} from "std/solana";
import { HostAccount, run } from "std/solana/host";

enum CounterOp { Init, Increment }

export struct Counter {
	authority: Pubkey;
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

export struct IncrementAccounts {
	authority: Signer;
	@seeds("counter") @bump(counter.bump) counter: Mutable<Counter>;
}

function init(): Result<uint64, ProgramError> {
	const x = try accounts<InitAccounts>();
	const made = try createPda<Counter>(x.payer, x.counter, ["counter"]);
	const counter = made.asMutable().data();
	counter.authority = x.payer.asAccount().key();
	counter.value = 0;
	counter.bump = made.foundBump();
	return Result.ok(0);
}

function increment(): Result<uint64, ProgramError> {
	const x = try accounts<IncrementAccounts>();
	const counter = x.counter.data();
	if (counter.authority != x.authority.asAccount().key()) {
		return Result.err(ProgramError.custom(6000));
	}
	counter.value += 1;
	return Result.ok(counter.value);
}

function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<CounterOp>()) {
		CounterOp.Init => init(),
		CounterOp.Increment => increment(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

// ---- Simulator: the transactions a client would send -----------------------

function keyOf(seed: uint8): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = seed;
	return key;
}

function holder(key: Pubkey, owner: Pubkey, lamports: uint64, signer: boolean): HostAccount {
	return { key: key, owner: owner, lamports: lamports, data: [], signer: signer, writable: true, executable: false };
}

function call(name: string): uint8[] {
	const tag = instructionDiscriminator(name);
	const bytes: uint8[] = [];
	for (let i = 0; i < 8; i++) { bytes.push(tag.bytes[i]); }
	return bytes;
}

function valueOf(counter: HostAccount): uint64 {
	let value: uint64 = 0;
	for (let i = 47; i >= 40; i--) { value = (value << 8) | (counter.data[i] as uint64); }
	return value;
}

function report(label: string, result: uint64, counter: HostAccount): void {
	const mark = result == 0 ? "✓" : "✗";
	const outcome = result == 0 ? "ok" : `refused by the program, error ${result}`;
	console.log(`${mark} ${label}: ${outcome}`);
	if (counter.data.length > 0) {
		console.log(`    counter = ${valueOf(counter)} · account holds ${counter.data.length} bytes, ${counter.lamports} lamports of rent`);
	}
}

const program = keyOf(9);
const alice = keyOf(1);
const mallory = keyOf(2);
const address = findProgramAddressOf(program, ["counter"]);

if (address.ok) {
	console.log(`counter lives at ${address.value.key.toBase58()}`);
	const system = { ...holder(SYSTEM_PROGRAM_ID, Pubkey.zero(), 1, false), writable: false, executable: true };
	const created: HostAccount[] = [
		holder(alice, SYSTEM_PROGRAM_ID, 10000000000, true),
		holder(address.value.key, SYSTEM_PROGRAM_ID, 0, false),
		system,
	];
	report("alice creates the counter", run(program, created, call("Init"), entry).result, created[1]);

	const counted: HostAccount[] = [holder(alice, SYSTEM_PROGRAM_ID, 0, true), created[1]];
	report("alice increments", run(program, counted, call("Increment"), entry).result, counted[1]);
	report("alice increments again", run(program, counted, call("Increment"), entry).result, counted[1]);

	const forged: HostAccount[] = [holder(mallory, SYSTEM_PROGRAM_ID, 0, true), counted[1]];
	report("mallory increments alice's counter", run(program, forged, call("Increment"), entry).result, forged[1]);
}
