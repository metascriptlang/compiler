import { InstructionAccount, account, accountCount, failWith, instructionData, invokeList, putU8 } from "./core";
import { ProgramError } from "./error";
import { HostAccount, HostRun, NOT_SIMULATED, run } from "./host";
import { ASSOCIATED_TOKEN_PROGRAM_ID, Pubkey, SYSTEM_PROGRAM_ID, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID } from "./pubkey";
import { findAddress } from "./simulatorCryptoCore";
import { FORWARD, NONE, hostProgramEntry } from "./testHostProgram";

const FUNDS: uint64 = 100000000;
const DISCRIMINATORS: uint8[] = [0, 1];

function keyOf(seed: uint8): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = seed;
	return key;
}

function zeros(count: int32): uint8[] {
	const bytes: uint8[] = [];
	for (let index = 0; index < count; index++) { bytes.push(0); }
	return bytes;
}

function holder(key: Pubkey, owner: Pubkey, data: uint8[]): HostAccount {
	return { key: key, owner: owner, lamports: FUNDS, data: data, signer: true, writable: true, executable: false };
}

function programAccount(program: Pubkey): HostAccount {
	return { ...holder(program, keyOf(0), []), executable: true };
}

function plain(seed: uint8): HostAccount {
	return holder(keyOf(seed), SYSTEM_PROGRAM_ID, []);
}

function tokenAccountOf(program: Pubkey, seed: uint8, mint: uint8, owner: uint8): HostAccount {
	const data = zeros(165);
	data[0] = mint;
	data[32] = owner;
	data[64] = 10;
	data[108] = 1;
	return holder(keyOf(seed), program, data);
}

function sent(program: Pubkey, accounts: HostAccount[], instruction: uint8[]): HostRun {
	const data: uint8[] = [FORWARD, NONE, accounts.length as uint8, 3, 3, 3, 3, 0, 0, 0];
	for (const byte of instruction) { data.push(byte); }
	const held: HostAccount[] = [programAccount(program), ...accounts];
	const outcome = run(keyOf(9), held, data, hostProgramEntry);
	for (let index = 0; index < accounts.length; index++) { accounts[index] = held[index + 1]; }
	return outcome;
}

function amountTail(tag: uint8, tail: int32): uint8[] {
	const data: uint8[] = [tag, 1, 0, 0, 0, 0, 0, 0, 0];
	for (let index = 0; index < tail; index++) { data.push(0); }
	return data;
}

function answers(outcome: HostRun, expected: ProgramError): boolean {
	return outcome.result == expected.code && outcome.fault == "";
}

// host.c msSolHostToken, the account-count refusal of each instruction
test "a token instruction sent fewer accounts than it names is NotEnoughAccountKeys, whatever its data holds" {
	const missing = ProgramError.notEnoughAccountKeys();
	const noAccounts: uint8[][] = [
		amountTail(3, 0), amountTail(7, 0), [9], amountTail(12, 1), [5], [6, 0, 0], amountTail(8, 0), amountTail(15, 1),
		amountTail(13, 1), [18, ...zeros(32)], [20, ...zeros(34)],
	];
	for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
		for (const instruction of noAccounts) {
			assert answers(sent(program, [], instruction), missing);
		}
		const two: HostAccount[] = [plain(1), plain(2)];
		const three: HostAccount[] = [plain(1), plain(2), plain(3)];
		assert answers(sent(program, two.slice(0, 1), amountTail(3, 0)), missing);
		assert answers(sent(program, two, amountTail(7, 0)), missing);
		assert answers(sent(program, two, [9]), missing);
		assert answers(sent(program, two, amountTail(8, 0)), missing);
		assert answers(sent(program, three, amountTail(12, 1)), missing);
		assert answers(sent(program, two.slice(0, 1), [6, 0, 0]), missing);
		assert answers(sent(program, two.slice(0, 1), [18, ...zeros(32)]), missing);
	}
}

// host.c msSolHostAuthorized
test "a token authority that is a multisignature account fails the run as not simulated" {
	for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
		const authority = holder(keyOf(30), program, zeros(355));
		const accounts: HostAccount[] = [tokenAccountOf(program, 1, 5, 30), tokenAccountOf(program, 2, 5, 31), authority];
		const outcome = sent(program, accounts, amountTail(3, 0));
		assert outcome.result == NOT_SIMULATED;
		assert outcome.fault == "sol_invoke_signed: a multisignature token authority is not simulated";
		const burning: HostAccount[] = [tokenAccountOf(program, 1, 5, 30), holder(keyOf(5), program, mintBytes()), authority];
		assert sent(program, burning, amountTail(8, 0)).fault
			== "sol_invoke_signed: a multisignature token authority is not simulated";
	}
}

function mintBytes(): uint8[] {
	const data = zeros(82);
	data[0] = 1;
	data[4] = 30;
	data[45] = 1;
	return data;
}

// host.c msSolHostCloseAccount
test "closeAccount refuses lamports that overflow the destination, and a Token-2022 mint with a close authority" {
	const wide: uint64 = 0xc000000000000000;
	const source: HostAccount = { ...tokenAccountOf(TOKEN_PROGRAM_ID, 1, 5, 3), lamports: wide };
	source.data[64] = 0;
	const destination: HostAccount = { ...plain(2), lamports: wide };
	const overflow = sent(TOKEN_PROGRAM_ID, [source, destination, plain(3)], [9]);
	assert overflow.result == 14 && overflow.fault == "";

	const mint = zeros(202);
	mint[45] = 1;
	mint[165] = 1;
	mint[166] = 3;
	mint[168] = 32;
	const closing = sent(TOKEN_2022_PROGRAM_ID, [holder(keyOf(1), TOKEN_2022_PROGRAM_ID, mint), plain(2), plain(3)], [9]);
	assert closing.result == NOT_SIMULATED;
	assert closing.fault == "sol_invoke_signed: closing a Token-2022 mint that has a close authority is not simulated";
	mint[166] = 5;
	const other = sent(TOKEN_2022_PROGRAM_ID, [holder(keyOf(1), TOKEN_2022_PROGRAM_ID, mint), plain(2), plain(3)], [9]);
	assert other.fault == "" && other.result != NOT_SIMULATED;
}

// host.c msSolHostInitializeAccount3, the extension space
test "InitializeAccount3 on a Token-2022 account too small for its mint's extensions is InvalidAccountData, and one sized for them takes them" {
	const mint = zeros(170);
	mint[45] = 1;
	mint[165] = 1;
	mint[166] = 9;
	const owner: uint8[] = [18, 7, ...zeros(31)];
	const rent165: uint64 = 2039280;
	const small: HostAccount = { ...holder(keyOf(4), TOKEN_2022_PROGRAM_ID, zeros(165)), lamports: rent165 };
	const refused = sent(TOKEN_2022_PROGRAM_ID, [small, holder(keyOf(1), TOKEN_2022_PROGRAM_ID, mint)], owner);
	assert answers(refused, ProgramError.invalidAccountData());
	const fitted: HostAccount = { ...holder(keyOf(4), TOKEN_2022_PROGRAM_ID, zeros(174)), lamports: 2101920 };
	const accounts: HostAccount[] = [fitted, holder(keyOf(1), TOKEN_2022_PROGRAM_ID, mint)];
	assert sent(TOKEN_2022_PROGRAM_ID, accounts, owner).result == 0;
	const written = accounts[0].data;
	assert written[108] == 1 && written[165] == 2 && written[32] == 7;
	const extensions: uint8[] = [13, 0, 0, 0, 7, 0, 0, 0];
	for (let index = 0; index < 8; index++) { assert written[166 + index] == extensions[index]; }
}

// host.c msSolHostSetAuthority, msSolHostInitializeMint2
test "SetAuthority and InitializeMint2 read no byte past their data, and SetAuthority of an owner needs a next owner" {
	for (const program of [TOKEN_PROGRAM_ID, TOKEN_2022_PROGRAM_ID]) {
		const short = program == TOKEN_PROGRAM_ID ? ProgramError.custom(12) : ProgramError.invalidInstructionData();
		const target: HostAccount[] = [tokenAccountOf(program, 1, 5, 2), plain(2)];
		const authorities: uint8[][] = [[6], [6, 2], [6, 2, 2, ...zeros(34)], [6, 2, 1, ...zeros(31)]];
		for (const data of authorities) { assert answers(sent(program, target, data), short); }
		const mints: uint8[][] = [[20], [20, 0], [20, 0, ...zeros(32)], [20, 0, ...zeros(32), 2], [20, 0, ...zeros(32), 1, ...zeros(31)]];
		for (const data of mints) { assert answers(sent(program, [holder(keyOf(1), program, zeros(82))], data), short); }
		assert answers(sent(program, target, [6, 2, 0]), ProgramError.custom(12));
	}
}

function associatedStep(): Result<uint64, ProgramError> {
	const input = instructionData();
	const last = accountCount() - 1;
	let metas: InstructionAccount[] = [];
	for (let index = 0; index < last; index++) { metas.push(InstructionAccount.flagged(try account(index), true, true)); }
	let storage: uint8[2] = [];
	let length: uint64 = 0;
	for (let at: uint64 = 0; at < input.length; at++) { length = putU8(storage, length, try input.readU8(at)); }
	return invokeList((try account(last)).key(), metas, storage, length);
}

function associatedEntry(): void {
	const result = associatedStep();
	if (!result.ok) { failWith(result.error); }
}

function associatedAddress(wallet: Pubkey, program: Pubkey, mint: Pubkey): Pubkey {
	const seeds: uint8[] = [];
	for (const key of [wallet, program, mint]) {
		for (let index = 0; index < 32; index++) { seeds.push(key.bytes[index]); }
	}
	return { bytes: findAddress(seeds, ASSOCIATED_TOKEN_PROGRAM_ID.bytes).digest.bytes };
}

function associatedAccounts(program: Pubkey, target: Pubkey): HostAccount[] {
	return [
		plain(4),
		{ ...holder(target, SYSTEM_PROGRAM_ID, []), lamports: 0 },
		plain(2),
		holder(keyOf(1), program, mintBytes()),
		holder(SYSTEM_PROGRAM_ID, keyOf(0), []),
		programAccount(program),
		programAccount(ASSOCIATED_TOKEN_PROGRAM_ID),
	];
}

function associatedRun(accounts: HostAccount[], discriminator: uint8): HostRun {
	return run(keyOf(9), accounts, [discriminator], associatedEntry);
}

// host.c msSolHostAssociated
test "an Associated Token instruction sent fewer than six accounts is NotEnoughAccountKeys" {
	const accounts = associatedAccounts(TOKEN_PROGRAM_ID, keyOf(60));
	const callee = accounts[6];
	for (const count of [0, 1, 4, 5]) {
		const sentAccounts = accounts.slice(0, count);
		sentAccounts.push(callee);
		for (const discriminator of DISCRIMINATORS) {
			assert answers(associatedRun(sentAccounts, discriminator), ProgramError.notEnoughAccountKeys());
		}
	}
}

test "an associated account under a program that is not a token program, or at an address holding data, fails the run as not simulated" {
	const foreign = keyOf(77);
	const accounts = associatedAccounts(TOKEN_PROGRAM_ID, associatedAddress(keyOf(2), foreign, keyOf(1)));
	accounts[5] = programAccount(foreign);
	for (const discriminator of DISCRIMINATORS) {
		const outcome = associatedRun(accounts, discriminator);
		assert outcome.result == NOT_SIMULATED;
		assert outcome.fault == "sol_invoke_signed: an associated account under a program that is not a token program is not simulated";
	}
	const holding = associatedAccounts(TOKEN_PROGRAM_ID, associatedAddress(keyOf(2), TOKEN_PROGRAM_ID, keyOf(1)));
	holding[1].data = zeros(10);
	for (const discriminator of DISCRIMINATORS) {
		const outcome = associatedRun(holding, discriminator);
		assert outcome.result == NOT_SIMULATED;
		assert outcome.fault == "sol_invoke_signed: an associated account at a System-owned address that holds data is not simulated";
	}
}
