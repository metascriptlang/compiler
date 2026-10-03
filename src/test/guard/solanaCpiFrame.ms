// GUARD-OS solana
// The largest CPI shapes the std supports build for SBF inside the 4 KB frame: sixteen accounts
// written at the call beside a 1 KB data buffer, a signed one, and the run-time lists behind
// commit, scheduleTask and requestRandomness.
// RED MEANS: a CPI shape grew past the frame the SBF backend allows, or a helper stopped
// building its accounts and data on the caller's stack.
import {
	Account,
	AccountMeta,
	InstructionAccount,
	ProgramError,
	Pubkey,
	account,
	borshBuffer,
	failWith,
	instructionData,
	invoke,
	invokeList,
	programId,
	signed,
} from "std/solana";
import { commit, scheduleTask } from "std/solana/magicblock";
import { RandomnessRequest, requestRandomness } from "std/solana/vrf";

function sixteen(a: Account, b: Account): Result<uint64, ProgramError> {
	let storage: uint8[1024] = [];
	return invoke(
		programId(),
		[
			InstructionAccount.writable(a), InstructionAccount.writable(b),
			InstructionAccount.writable(a), InstructionAccount.writable(b),
			InstructionAccount.writable(a), InstructionAccount.writable(b),
			InstructionAccount.writable(a), InstructionAccount.writable(b),
			InstructionAccount.readonly(a), InstructionAccount.readonly(b),
			InstructionAccount.readonly(a), InstructionAccount.readonly(b),
			InstructionAccount.readonlySigner(a), InstructionAccount.readonlySigner(b),
			InstructionAccount.writableSigner(a), InstructionAccount.writableSigner(b),
		],
		borshBuffer(storage).u8(1).u64(2),
	);
}

function signedSixteen(a: Account, b: Account): Result<uint64, ProgramError> {
	let storage: uint8[1024] = [];
	return signed(
		invoke(
			programId(),
			[
				InstructionAccount.writable(a), InstructionAccount.writable(b),
				InstructionAccount.writable(a), InstructionAccount.writable(b),
				InstructionAccount.writable(a), InstructionAccount.writable(b),
				InstructionAccount.writable(a), InstructionAccount.writable(b),
				InstructionAccount.readonly(a), InstructionAccount.readonly(b),
				InstructionAccount.readonly(a), InstructionAccount.readonly(b),
				InstructionAccount.readonlySigner(a), InstructionAccount.readonlySigner(b),
				InstructionAccount.writableSigner(a), InstructionAccount.writableSigner(b),
			],
			borshBuffer(storage).u8(1).u64(2),
		),
		["pet", [1]],
	);
}

function listed(a: Account, count: int32): Result<uint64, ProgramError> {
	let metas: InstructionAccount[16];
	for (let index = 0; index < 16; index++) { metas[index] = InstructionAccount.writable(a); }
	let storage: uint8[1024] = [];
	return invokeList(programId(), metas[0..count], borshBuffer(storage).u8(1));
}

function committed(payer: Account, context: Account, vault: Account, count: int32): Result<uint64, ProgramError> {
	let list: Account[16];
	for (let index = 0; index < 16; index++) { list[index] = payer; }
	return commit(payer, list[0..count], context, vault);
}

function scheduledList(payer: Account, a: Account, b: Account): Result<uint64, ProgramError> {
	const task: InstructionAccount[2] = [InstructionAccount.writable(a), InstructionAccount.readonly(b)];
	const bytes = try instructionData().range(1, 2);
	return scheduleTask(payer, 1, 2, 3, programId(), task, bytes);
}

function randomness(a: Account, b: Account, c: Account, metas: AccountMeta[2]): Result<uint64, ProgramError> {
	const request: RandomnessRequest = {
		payer: a,
		programIdentity: b,
		oracleQueue: c,
		systemProgram: a,
		slotHashes: b,
	};
	const bytes = try instructionData().range(1, 2);
	return requestRandomness(request, Pubkey.zero(), 1, metas, bytes);
}

function main(): void {
	const a = account(0);
	const b = account(1);
	const c = account(2);
	if (!a.ok || !b.ok || !c.ok) { return; }
	const op = instructionData().length;
	const metas: AccountMeta[2] = [AccountMeta.writable(Pubkey.zero()), AccountMeta.readonly(Pubkey.zero())];
	let result = sixteen(a.value, b.value);
	if (op == 1) { result = signedSixteen(a.value, b.value); }
	if (op == 2) { result = listed(a.value, op as int32); }
	if (op == 3) { result = committed(a.value, b.value, c.value, op as int32); }
	if (op == 4) { result = scheduledList(a.value, b.value, c.value); }
	if (op == 5) { result = randomness(a.value, b.value, c.value, metas); }
	if (!result.ok) { failWith(result.error); }
}
main();
