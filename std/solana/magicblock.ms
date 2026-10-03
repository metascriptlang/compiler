import {
	Account,
	Bytes,
	InstructionAccount,
	MAX_CPI_ACCOUNTS,
	createProgramAccountSeeded,
	invokeList,
	putPubkey,
	putSpan,
	putU32,
	putU64,
	putU8,
} from "./core";
import { ProgramError } from "./error";
import { findProgramAddressOf } from "./macro";
import { Pubkey, pubkeyOf } from "./pubkey";
import { SeedTable, bytesAddress, findAt, tableAddress } from "./seed";

export { DelegationAccounts, DelegationConfig, anyValidator, delegationProgram, onValidator } from "./delegation";
export { delegate } from "./macro";

when (testBuild) {
	import { account, failWith, instructionData, programId, putBytes } from "./core";
	import {
		DelegationAccounts,
		DelegationConfig,
		anyValidator,
		delegationProgram,
		onValidator,
	} from "./delegation";
	import { delegate, findProgramAddress } from "./macro";
	import { HostAccount, invocations, run, signerIs, textBytes } from "./host";
}

export function magicProgram(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("Magic11111111111111111111111111111111111111"); };
}

export function magicContext(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("MagicContext1111111111111111111111111111111"); };
}

function scheduleCommit(
	payer: Account,
	committed: Span<Account>,
	magicContextAccount: Account,
	feeVault: Account | null,
	discriminant: uint32,
): Result<uint64, ProgramError> {
	if (!payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const prefix: uint64 = feeVault === null ? 2 : 3;
	if (prefix + (committed.length as uint64) > MAX_CPI_ACCOUNTS) {
		return Result.err(ProgramError.invalidArgument());
	}
	let metas: InstructionAccount[16];
	metas[0] = InstructionAccount.flagged(payer, payer.isWritable(), true);
	metas[1] = InstructionAccount.writable(magicContextAccount);
	if (feeVault !== null) { metas[2] = InstructionAccount.writable(feeVault); }
	let at = prefix as int32;
	for (const account of committed) {
		metas[at] = InstructionAccount.flagged(account, account.isWritable(), account.isSigner());
		at = at + 1;
	}
	let storage: uint8[4] = [];
	const length = putU32(storage, 0, discriminant);
	return invokeList(Pubkey.magicProgram(), metas[0..at], storage, length);
}

export function commit(payer: Account, committed: Account, magicContextAccount: Account): Result<uint64, ProgramError> {
	const accounts: Account[1] = [committed];
	return scheduleCommit(payer, accounts, magicContextAccount, null, 1);
}

export function commit(
	payer: Account,
	committed: Span<Account>,
	magicContextAccount: Account,
): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, null, 1);
}

export function commit(
	payer: Account,
	committed: Span<Account>,
	magicContextAccount: Account,
	feeVault: Account,
): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, feeVault, 1);
}

export function commitAndUndelegate(payer: Account, committed: Account, magicContextAccount: Account): Result<uint64, ProgramError> {
	const accounts: Account[1] = [committed];
	return scheduleCommit(payer, accounts, magicContextAccount, null, 2);
}

export function commitAndUndelegate(
	payer: Account,
	committed: Span<Account>,
	magicContextAccount: Account,
): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, null, 2);
}

export function commitAndUndelegate(
	payer: Account,
	committed: Span<Account>,
	magicContextAccount: Account,
	feeVault: Account,
): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, feeVault, 2);
}

export function isUndelegateCallback(data: Bytes): boolean {
	const expectedLow: uint32 = 0xce291cc4;
	const expectedHigh: uint32 = 0xa7332530;
	const low = try data.readU32(0) catch 0;
	const high = try data.readU32(4) catch 0;
	return low == expectedLow && high == expectedHigh;
}

function parseSeeds(data: Bytes, start: uint64, ref into: SeedTable): Result<uint64, ProgramError> {
	const count = try data.readU32(start);
	if (count == 0 || count > 16) { return Result.err(ProgramError.invalidInstructionData()); }
	let offset = start + 4;
	for (let index: uint32 = 0; index < count; index++) {
		const length = try data.readU32(offset);
		const view = try data.range(offset + 4, length as uint64);
		into.slices[index] = { address: view.address, length: view.length };
		offset = offset + 4 + (length as uint64);
	}
	if (offset != data.length) { return Result.err(ProgramError.invalidInstructionData()); }
	into.count = count as uint64;
	return Result.ok(into.count);
}

export function undelegate(delegated: Account, buffer: Account, payer: Account, ownerProgramId: Pubkey, callbackData: Bytes): Result<uint64, ProgramError> {
	if (!buffer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	if (!buffer.owner().equals(Pubkey.delegationProgram())) { return Result.err(ProgramError.invalidAccountOwner()); }
	const canonical = try findProgramAddressOf(
		Pubkey.delegationProgram(),
		["undelegate-buffer", delegated],
	);
	if (!canonical.key.equals(buffer.key())) { return Result.err(ProgramError.invalidSeeds()); }
	let seeds: SeedTable = { slices: [], bump: [0], count: 0 };
	const count = try parseSeeds(callbackData, 8, seeds);
	const expected = try findAt(
		tableAddress(seeds.slices),
		count,
		bytesAddress(ownerProgramId.bytes),
	);
	if (!expected.key.equals(delegated.key())) { return Result.err(ProgramError.invalidSeeds()); }
	const _created = try createProgramAccountSeeded(
		payer,
		delegated,
		buffer.dataLength(),
		ownerProgramId,
		seeds.slices[0..(count as int32)],
		expected.bump,
	);
	return delegated.data().copyFrom(buffer.data());
}

function scheduled(
	payer: Account,
	taskId: uint64,
	intervalMillis: uint64,
	iterations: uint64,
	taskProgram: Pubkey,
	taskAccounts: Span<InstructionAccount>,
	taskData: Readonly<Span<uint8>>,
): Result<uint64, ProgramError> {
	if (!payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const count = taskAccounts.length as uint64;
	if (1 + count > MAX_CPI_ACCOUNTS) { return Result.err(ProgramError.invalidArgument()); }
	let metas: InstructionAccount[16];
	metas[0] = InstructionAccount.writableSigner(payer);
	let storage: uint8[1024] = [];
	let length = putU32(storage, 0, 6);
	length = putU64(storage, length, taskId);
	length = putU64(storage, length, intervalMillis);
	length = putU64(storage, length, iterations);
	length = putU64(storage, length, 1);
	length = putPubkey(storage, length, taskProgram);
	length = putU64(storage, length, count);
	for (let index = 0; index < taskAccounts.length; index++) {
		const meta = taskAccounts[index];
		const held: Account = { address: meta.key - 8 };
		metas[index + 1] = InstructionAccount.flagged(held, held.isWritable(), held.isSigner());
		length = putPubkey(storage, length, meta.address());
		length = putU8(storage, length, meta.signer);
		length = putU8(storage, length, meta.writable);
	}
	length = putU64(storage, length, taskData.length as uint64);
	length = putSpan(storage, length, taskData);
	return invokeList(Pubkey.magicProgram(), metas[0..(1 + taskAccounts.length)], storage, length);
}

export function scheduleTask(
	payer: Account,
	taskId: uint64,
	intervalMillis: uint64,
	iterations: uint64,
	target: Account,
	targetData: Readonly<Span<uint8>>,
	targetProgram: Pubkey,
): Result<uint64, ProgramError> {
	const accounts: InstructionAccount[1] = [InstructionAccount.writable(target)];
	return scheduled(payer, taskId, intervalMillis, iterations, targetProgram, accounts, targetData);
}

export function scheduleTask(
	payer: Account,
	taskId: uint64,
	intervalMillis: uint64,
	iterations: uint64,
	targetProgram: Pubkey,
	targetAccounts: Span<InstructionAccount>,
	targetData: Readonly<Span<uint8>>,
): Result<uint64, ProgramError> {
	return scheduled(payer, taskId, intervalMillis, iterations, targetProgram, targetAccounts, targetData);
}

when (testBuild) {
	function keyOf(seed: uint8): Pubkey {
		let key = Pubkey.zero();
		key.bytes[0] = seed;
		return key;
	}

	function programKey(): Pubkey {
		return keyOf(9);
	}

	function holder(key: Pubkey, owner: Pubkey, data: uint8[]): HostAccount {
		return {
			key: key,
			owner: owner,
			lamports: 0,
			data: data,
			signer: false,
			writable: true,
			executable: false,
		};
	}

	function payerAccount(): HostAccount {
		const payer: HostAccount = {
			...holder(keyOf(1), Pubkey.systemProgram(), []),
			lamports: 10000000,
			signer: true,
		};
		return payer;
	}

	function programAccount(key: Pubkey): HostAccount {
		const program: HostAccount = {
			...holder(key, Pubkey.systemProgram(), []),
			writable: false,
			executable: true,
		};
		return program;
	}

	function sameBytes(left: uint8[], right: uint8[]): boolean {
		if (left.length != right.length) { return false; }
		for (let index = 0; index < left.length; index++) {
			if (left[index] != right[index]) { return false; }
		}
		return true;
	}

	function petKey(): Pubkey {
		const derived = findProgramAddressOf(programKey(), ["pet"]);
		if (derived.ok) { return derived.value.key; }
		return Pubkey.zero();
	}

	function delegateStep(): Result<uint64, ProgramError> {
		const pinned = try instructionData().readU8(0);
		const derived = try findProgramAddress(["pet"]);
		let config = DelegationConfig.anyValidator();
		if (pinned == 1) { config = DelegationConfig.onValidator(keyOf(77)); }
		const delegation: DelegationAccounts = {
			payer: try account(0),
			delegated: try account(1),
			ownerProgram: try account(2),
			buffer: try account(3),
			delegationRecord: try account(4),
			delegationMetadata: try account(5),
			systemProgram: try account(6),
		};
		return delegate(delegation, ["pet"], derived.bump, config);
	}

	function delegateEntry(): void {
		const result = delegateStep();
		if (!result.ok) { failWith(result.error); }
	}

	function delegationAccounts(): HostAccount[] {
		let buffer = Pubkey.zero();
		const found = findProgramAddressOf(programKey(), ["buffer", petKey()]);
		if (found.ok) { buffer = found.value.key; }
		const pet: HostAccount = { ...holder(petKey(), programKey(), [5, 6, 7, 8]), lamports: 900 };
		return [
			payerAccount(),
			pet,
			programAccount(programKey()),
			holder(buffer, Pubkey.systemProgram(), []),
			holder(keyOf(4), Pubkey.systemProgram(), []),
			holder(keyOf(5), Pubkey.systemProgram(), []),
			programAccount(Pubkey.systemProgram()),
		];
	}

	function delegateRun(accounts: HostAccount[], pinned: uint8): uint64 {
		const input: uint8[] = [pinned];
		return run(programKey(), accounts, input, delegateEntry).result;
	}

	test "delegate copies through a buffer, then sends the delegation program its seven accounts" {
		const accounts = delegationAccounts();
		assert delegateRun(accounts, 0) == 0;
		const calls = invocations();
		assert calls.length == 3;
		assert calls[0].program.equals(Pubkey.systemProgram()) && calls[0].data[0] == 0;
		assert calls[0].accounts[1].key.equals(accounts[3].key);
		assert calls[1].program.equals(Pubkey.systemProgram()) && calls[1].data[0] == 1;
		assert calls[1].accounts[0].key.equals(petKey()) && calls[1].signers == 1;
		const sent = calls[2];
		assert sent.program.equals(Pubkey.delegationProgram());
		assert sent.accounts.length == 7;
		assert sent.accounts[0].key.equals(keyOf(1));
		assert sent.accounts[0].writable && sent.accounts[0].signer;
		assert sent.accounts[1].key.equals(petKey());
		assert sent.accounts[1].writable && sent.accounts[1].signer;
		assert sent.accounts[2].key.equals(programKey());
		assert !sent.accounts[2].writable && !sent.accounts[2].signer;
		assert sent.accounts[3].writable && !sent.accounts[3].signer;
		assert sent.accounts[4].writable && sent.accounts[5].writable;
		assert sent.accounts[6].key.equals(Pubkey.systemProgram()) && !sent.accounts[6].writable;
		const args: uint8[] = [
			0, 0, 0, 0, 0, 0, 0, 0,
			255, 255, 255, 255,
			1, 0, 0, 0,
			3, 0, 0, 0, 112, 101, 116,
			0,
		];
		assert sameBytes(sent.data, args);
	}

	function keyBytes(key: Pubkey): uint8[] {
		const bytes: uint8[] = [];
		for (let index = 0; index < 32; index++) { bytes.push(key.bytes[index]); }
		return bytes;
	}

	test "delegate signs the buffer, the assign and the delegation with their seeds and bumps" {
		const accounts = delegationAccounts();
		assert delegateRun(accounts, 0) == 0;
		const calls = invocations();
		const pet = findProgramAddressOf(programKey(), ["pet"]);
		const buffer = findProgramAddressOf(programKey(), ["buffer", petKey()]);
		assert pet.ok && buffer.ok;
		if (pet.ok && buffer.ok) {
			const bufferSeeds = [textBytes("buffer"), keyBytes(petKey()), [buffer.value.bump]];
			assert calls[0].signers == 1 && signerIs(calls[0], 0, bufferSeeds);
			assert calls[1].signers == 1 && signerIs(calls[1], 0, [textBytes("pet"), [pet.value.bump]]);
			assert calls[2].signers == 1 && signerIs(calls[2], 0, [textBytes("pet"), [pet.value.bump]]);
		}
	}

	test "delegate zeroes the account, hands it to the delegation program and closes the buffer" {
		const accounts = delegationAccounts();
		assert delegateRun(accounts, 0) == 0;
		assert accounts[1].owner.equals(Pubkey.delegationProgram());
		assert accounts[1].data.length == 4 && accounts[1].data[0] == 0 && accounts[1].data[3] == 0;
		assert accounts[3].lamports == 0 && accounts[3].data.length == 0;
		assert accounts[3].owner.equals(Pubkey.systemProgram());
	}

	test "delegate to one validator ends the args with Some and the validator's key" {
		const accounts = delegationAccounts();
		assert delegateRun(accounts, 1) == 0;
		const sent = invocations()[2];
		assert sent.data.length == 56;
		assert sent.data[23] == 1 && sent.data[24] == 77 && sent.data[55] == 0;
	}

	test "delegate refuses an unsigned payer and a buffer at another address" {
		const unsigned = delegationAccounts();
		unsigned[0] = { ...unsigned[0], signer: false };
		assert delegateRun(unsigned, 0) == ProgramError.missingRequiredSignature().code;
		const misplaced = delegationAccounts();
		misplaced[3] = holder(keyOf(3), Pubkey.systemProgram(), []);
		assert delegateRun(misplaced, 0) == ProgramError.invalidSeeds().code;
		assert invocations().length == 0;
	}

	function commitStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const payer = try account(0);
		const context = try account(1);
		const vault = try account(2);
		const committed: Account[2] = [try account(3), try account(4)];
		return match (op) {
			0 => commit(payer, committed[0], context),
			1 => commit(payer, committed, context),
			2 => commit(payer, committed, context, vault),
			3 => commitAndUndelegate(payer, committed[0], context),
			4 => commitAndUndelegate(payer, committed, context),
			_ => commitAndUndelegate(payer, committed, context, vault),
		};
	}

	function commitEntry(): void {
		const result = commitStep();
		if (!result.ok) { failWith(result.error); }
	}

	function commitAccounts(): HostAccount[] {
		const readonly: HostAccount = {
			...holder(keyOf(5), Pubkey.delegationProgram(), []),
			writable: false,
		};
		return [
			payerAccount(),
			holder(Pubkey.magicContext(), Pubkey.magicProgram(), []),
			holder(keyOf(3), Pubkey.systemProgram(), []),
			holder(keyOf(4), Pubkey.delegationProgram(), []),
			readonly,
		];
	}

	function commitRun(accounts: HostAccount[], op: uint8): uint64 {
		const input: uint8[] = [op];
		return run(programKey(), accounts, input, commitEntry).result;
	}

	test "commit sends discriminant 1 to the magic program: payer, magic context, then the account" {
		assert commitRun(commitAccounts(), 0) == 0;
		const sent = invocations()[0];
		assert sent.program.equals(Pubkey.magicProgram());
		assert sent.accounts.length == 3;
		assert sent.accounts[0].key.equals(keyOf(1));
		assert sent.accounts[0].signer && sent.accounts[0].writable;
		assert sent.accounts[1].key.equals(Pubkey.magicContext());
		assert sent.accounts[1].writable && !sent.accounts[1].signer;
		assert sent.accounts[2].key.equals(keyOf(4)) && sent.accounts[2].writable;
		const data: uint8[] = [1, 0, 0, 0];
		assert sameBytes(sent.data, data);
	}

	test "a committed list keeps each account's flags, and a fee vault sits third" {
		assert commitRun(commitAccounts(), 1) == 0;
		const listed = invocations()[0];
		assert listed.accounts.length == 4;
		assert listed.accounts[2].key.equals(keyOf(4)) && listed.accounts[2].writable;
		assert listed.accounts[3].key.equals(keyOf(5)) && !listed.accounts[3].writable;
		assert commitRun(commitAccounts(), 2) == 0;
		const vaulted = invocations()[0];
		assert vaulted.accounts.length == 5;
		assert vaulted.accounts[2].key.equals(keyOf(3));
		assert vaulted.accounts[2].writable && !vaulted.accounts[2].signer;
		assert vaulted.accounts[3].key.equals(keyOf(4)) && vaulted.accounts[4].key.equals(keyOf(5));
		const data: uint8[] = [1, 0, 0, 0];
		assert sameBytes(vaulted.data, data);
	}

	test "commitAndUndelegate sends discriminant 2 in the same three shapes" {
		const data: uint8[] = [2, 0, 0, 0];
		assert commitRun(commitAccounts(), 3) == 0;
		assert invocations()[0].accounts.length == 3 && sameBytes(invocations()[0].data, data);
		assert commitRun(commitAccounts(), 4) == 0;
		assert invocations()[0].accounts.length == 4 && sameBytes(invocations()[0].data, data);
		assert commitRun(commitAccounts(), 5) == 0;
		const vaulted = invocations()[0];
		assert vaulted.accounts.length == 5 && vaulted.accounts[2].key.equals(keyOf(3));
		assert sameBytes(vaulted.data, data);
	}

	test "a commit without the payer's signature is refused before it is sent" {
		const accounts = commitAccounts();
		accounts[0] = { ...accounts[0], signer: false };
		assert commitRun(accounts, 2) == ProgramError.missingRequiredSignature().code;
		assert invocations().length == 0;
	}

	function scheduleStep(): Result<uint64, ProgramError> {
		const data = instructionData();
		const op = try data.readU8(0);
		const payer = try account(0);
		const tail = try data.range(1, 2);
		let relay: uint8[2] = [];
		const relayed = putBytes(relay, 0, tail);
		if (relayed != 2) { return Result.err(ProgramError.invalidInstructionData()); }
		if (op == 0) {
			return scheduleTask(payer, 7, 400, 3, try account(1), relay, programId());
		}
		const task: InstructionAccount[2] = [
			InstructionAccount.writable(try account(1)),
			InstructionAccount.readonly(try account(2)),
		];
		return scheduleTask(payer, 7, 400, 3, programId(), task, relay);
	}

	function scheduleEntry(): void {
		const result = scheduleStep();
		if (!result.ok) { failWith(result.error); }
	}

	function scheduleAccounts(): HostAccount[] {
		const readonly: HostAccount = {
			...holder(keyOf(5), Pubkey.delegationProgram(), []),
			writable: false,
		};
		return [payerAccount(), holder(keyOf(4), Pubkey.delegationProgram(), []), readonly];
	}

	function scheduleRun(op: uint8): uint64 {
		const input: uint8[] = [op, 0xaa, 0xbb];
		return run(programKey(), scheduleAccounts(), input, scheduleEntry).result;
	}

	function scheduleHead(): uint8[] {
		const head: uint8[] = [
			6, 0, 0, 0,
			7, 0, 0, 0, 0, 0, 0, 0,
			144, 1, 0, 0, 0, 0, 0, 0,
			3, 0, 0, 0, 0, 0, 0, 0,
			1, 0, 0, 0, 0, 0, 0, 0,
		];
		const sent = head.concat(keyBytes(programKey()));
		return sent;
	}

	test "scheduleTask sends the magic program the payer, the task's accounts and the task encoded" {
		assert scheduleRun(0) == 0;
		const single = invocations()[0];
		assert single.program.equals(Pubkey.magicProgram());
		assert single.accounts.length == 2;
		assert single.accounts[0].key.equals(keyOf(1));
		assert single.accounts[0].writable && single.accounts[0].signer;
		assert single.accounts[1].key.equals(keyOf(4));
		assert single.accounts[1].writable && !single.accounts[1].signer;
		const oneAccount: uint8[] = [1, 0, 0, 0, 0, 0, 0, 0];
		const meta: uint8[] = [0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb];
		const singleBytes = scheduleHead().concat(oneAccount).concat(keyBytes(keyOf(4))).concat(meta);
		assert sameBytes(single.data, singleBytes);

		assert scheduleRun(1) == 0;
		const listed = invocations()[0];
		assert listed.program.equals(Pubkey.magicProgram());
		assert listed.accounts.length == 3;
		assert listed.accounts[1].key.equals(keyOf(4)) && listed.accounts[1].writable;
		assert listed.accounts[2].key.equals(keyOf(5)) && !listed.accounts[2].writable;
		assert !listed.accounts[1].signer && !listed.accounts[2].signer;
		const twoAccounts: uint8[] = [2, 0, 0, 0, 0, 0, 0, 0];
		const first: uint8[] = [0, 1];
		const second: uint8[] = [0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb];
		const listBytes = scheduleHead()
			.concat(twoAccounts)
			.concat(keyBytes(keyOf(4)))
			.concat(first)
			.concat(keyBytes(keyOf(5)))
			.concat(second);
		assert sameBytes(listed.data, listBytes);
	}

	function countedStep(): Result<uint64, ProgramError> {
		const data = instructionData();
		const count = try data.readU8(0);
		const withVault = try data.readU8(1);
		const payer = try account(0);
		const context = try account(1);
		const vault = try account(2);
		let list: Account[16];
		for (let index = 0; index < 16; index++) { list[index] = try account(3 + index); }
		const some = list[0..(count as int32)];
		if (withVault == 1) { return commit(payer, some, context, vault); }
		return commit(payer, some, context);
	}

	function countedEntry(): void {
		const result = countedStep();
		if (!result.ok) { failWith(result.error); }
	}

	function countedRun(count: uint8, withVault: uint8): uint64 {
		const accounts = commitAccounts();
		for (let index = 0; index < 16; index++) {
			accounts.push(holder(keyOf((20 + index) as uint8), Pubkey.delegationProgram(), []));
		}
		const input: uint8[] = [count, withVault];
		return run(programKey(), accounts, input, countedEntry).result;
	}

	test "a committed list fills sixteen accounts with the payer and the context, and one more is refused" {
		assert countedRun(14, 0) == 0;
		const sent = invocations()[0];
		assert sent.accounts.length == 16;
		assert sent.accounts[2].key.equals(keyOf(4)) && sent.accounts[3].key.equals(keyOf(5));
		assert sent.accounts[4].key.equals(keyOf(20)) && sent.accounts[15].key.equals(keyOf(31));
		assert countedRun(15, 0) == ProgramError.invalidArgument().code;
		assert invocations().length == 0;
		assert countedRun(13, 1) == 0;
		assert invocations()[0].accounts.length == 16;
		assert countedRun(14, 1) == ProgramError.invalidArgument().code;
		assert invocations().length == 0;
	}

	function undelegateStep(): Result<uint64, ProgramError> {
		const data = instructionData();
		if (!isUndelegateCallback(data)) { return Result.err(ProgramError.invalidInstructionData()); }
		return undelegate(try account(0), try account(1), try account(2), programId(), data);
	}

	function undelegateEntry(): void {
		const result = undelegateStep();
		if (!result.ok) { failWith(result.error); }
	}

	function undelegateBuffer(): Pubkey {
		const found = findProgramAddressOf(
			Pubkey.delegationProgram(),
			["undelegate-buffer", petKey()],
		);
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	function undelegateAccounts(buffer: Pubkey): HostAccount[] {
		const held: HostAccount = {
			...holder(buffer, Pubkey.delegationProgram(), [7, 8, 9]),
			signer: true,
		};
		return [
			holder(petKey(), Pubkey.systemProgram(), []),
			held,
			payerAccount(),
			programAccount(Pubkey.systemProgram()),
		];
	}

	function callbackData(): uint8[] {
		return [196, 28, 41, 206, 48, 37, 51, 167, 1, 0, 0, 0, 3, 0, 0, 0, 112, 101, 116];
	}

	function undelegateRun(buffer: Pubkey, data: uint8[]): uint64 {
		return run(programKey(), undelegateAccounts(buffer), data, undelegateEntry).result;
	}

	test "undelegate rebuilds the account from the delegation program's buffer" {
		const accounts = undelegateAccounts(undelegateBuffer());
		assert run(programKey(), accounts, callbackData(), undelegateEntry).result == 0;
		assert accounts[0].owner.equals(programKey()) && accounts[0].lamports > 0;
		const restored: uint8[] = [7, 8, 9];
		assert sameBytes(accounts[0].data, restored);
	}

	test "undelegate refuses another callback, a foreign buffer and trailing seed bytes" {
		const other = callbackData();
		other[0] = 0;
		const malformed = ProgramError.invalidInstructionData().code;
		assert undelegateRun(undelegateBuffer(), other) == malformed;
		assert undelegateRun(keyOf(6), callbackData()) == ProgramError.invalidSeeds().code;
		const trailing = callbackData();
		trailing.push(0);
		assert undelegateRun(undelegateBuffer(), trailing) == malformed;
	}
}
