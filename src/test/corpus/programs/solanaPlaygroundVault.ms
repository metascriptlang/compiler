// @stdout: ✓ alice withdraws 0.25 SOL: ok
// @stdout: ✗ mallory withdraws from alice's vault: refused by the program, ConstraintSeeds (2006)
// @skip-raiser: std/solana has memory and kernel modules for C and JS only
// note: the geass playground's vault program; the Solana program and its host simulator print the same lines on C and JS. Its enums drop `export`: a JS bundle exports no enum.

// A vault program. Each user gets a PDA that holds their lamports.
// Press Run: it compiles to native code and executes against a simulated
// Solana runtime. No wallet, no validator, no deploy.

import {
	Program, ProgramError, Pubkey, System, SYSTEM_PROGRAM_ID, Writable, WritablePda,
	WritableSigner, accounts, args, asAccount, bump, failWith, findProgramAddressOf, instruction,
	instructionDiscriminator, seeds, signed, transfer,
} from "std/solana";
import { HostAccount, run } from "std/solana/host";

enum VaultOp {
	Deposit,
	Withdraw,
}

export struct AmountArgs {
	amount: uint64;
}

export struct DepositAccounts {
	user: WritableSigner;
	@seeds("vault", user) @bump vault: Writable;
	systemProgram: Program<System>;
}

export struct WithdrawAccounts {
	user: WritableSigner;
	@seeds("vault", user) @bump vault: WritablePda;
	systemProgram: Program<System>;
}

function deposit(): Result<uint64, ProgramError> {
	const given = try args<AmountArgs>();
	const x = try accounts<DepositAccounts>();
	return transfer(x.user.asAccount(), x.vault.asAccount(), given.amount);
}

function withdraw(): Result<uint64, ProgramError> {
	const given = try args<AmountArgs>();
	const x = try accounts<WithdrawAccounts>();
	return signed(
		transfer(x.vault.asAccount(), x.user.asAccount(), given.amount),
		["vault", x.user, [x.vault.foundBump()]],
	);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<VaultOp>()) {
		VaultOp.Deposit => deposit(),
		VaultOp.Withdraw => withdraw(),
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

function call(name: string, amount: uint64): uint8[] {
	const tag = instructionDiscriminator(name);
	const bytes: uint8[] = [];
	for (let i = 0; i < 8; i++) { bytes.push(tag.bytes[i]); }
	for (let shift: uint64 = 0; shift < 64; shift += 8) { bytes.push(((amount >> shift) & 255) as uint8); }
	return bytes;
}

function nameOf(code: uint64): string {
	if (code == 3010) { return "AccountNotSigner (3010)"; }
	if (code == 2006) { return "ConstraintSeeds (2006)"; }
	return `error ${code}`;
}

function report(label: string, result: uint64, held: HostAccount[]): void {
	const mark = result == 0 ? "✓" : "✗";
	const outcome = result == 0 ? "ok" : `refused by the program, ${nameOf(result)}`;
	console.log(`${mark} ${label}: ${outcome}`);
	console.log(`    user ${held[0].lamports} lamports · vault ${held[1].lamports} lamports`);
}

const program = keyOf(9);
const alice = keyOf(1);
const mallory = keyOf(2);
const vault = findProgramAddressOf(program, ["vault", alice]);

if (vault.ok) {
	console.log(`program ${program.toBase58()}`);
	console.log(`vault   ${vault.value.key.toBase58()} (bump ${vault.value.bump})`);
	const system = { ...holder(SYSTEM_PROGRAM_ID, Pubkey.zero(), 1, false), writable: false, executable: true };

	const held: HostAccount[] = [
		holder(alice, SYSTEM_PROGRAM_ID, 10000000000, true),
		holder(vault.value.key, SYSTEM_PROGRAM_ID, 0, false),
		system,
	];
	report("alice deposits 1 SOL", run(program, held, call("Deposit", 1000000000), entry).result, held);
	report("alice withdraws 0.25 SOL", run(program, held, call("Withdraw", 250000000), entry).result, held);

	held[0].signer = false;
	report("withdraw without alice's signature", run(program, held, call("Withdraw", 250000000), entry).result, held);

	const stolen: HostAccount[] = [holder(mallory, SYSTEM_PROGRAM_ID, 10000000000, true), held[1], system];
	report("mallory withdraws from alice's vault", run(program, stolen, call("Withdraw", 250000000), entry).result, stolen);
}
