import {
	Account,
	Bytes,
	Instruction,
	Seeds,
	assignTo,
	createAccount,
	createProgramAccount,
} from "./core";
import { ProgramError } from "./error";
import { Pubkey, pubkeyOf } from "./pubkey";

when (testBuild) {
	import { account, failWith, instructionData, programId } from "./core";
	import { HostAccount, invocations, run } from "./host";
}

export struct DelegationAccounts {
	payer: Account;
	delegated: Account;
	ownerProgram: Account;
	buffer: Account;
	delegationRecord: Account;
	delegationMetadata: Account;
	systemProgram: Account;
}

export struct DelegationConfig {
	commitFrequencyMs: uint32;
	validator: Pubkey;
}

export function delegationProgram(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("DELeGGvXpWV2fqJUhqcF5ZSYMS4JTLjteaAMARRSaeSh"); };
}

export function magicProgram(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("Magic11111111111111111111111111111111111111"); };
}

export function magicContext(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("MagicContext1111111111111111111111111111111"); };
}

export function anyValidator(this typeof DelegationConfig): DelegationConfig {
	const unlimited: uint32 = 0xffffffff;
	const config: DelegationConfig = { commitFrequencyMs: unlimited, validator: Pubkey.zero() };
	return config;
}

export function onValidator(this typeof DelegationConfig, validator: Pubkey): DelegationConfig {
	const unlimited: uint32 = 0xffffffff;
	const config: DelegationConfig = { commitFrequencyMs: unlimited, validator: validator };
	return config;
}

function closeBuffer(payer: Account, buffer: Account): Result<uint64, ProgramError> {
	const reclaimed = buffer.lamports();
	payer.setLamports(payer.lamports() + reclaimed);
	buffer.setLamports(0);
	const _emptied = try buffer.resize(0);
	buffer.assign(Pubkey.systemProgram());
	return Result.ok(reclaimed);
}

export function delegate(accounts: DelegationAccounts, seeds: Seeds, bump: uint8, config: DelegationConfig): Result<uint64, ProgramError> {
	if (!accounts.payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const ownerKey = accounts.ownerProgram.key();
	const bufferSeeds = Seeds.empty(2).addText("buffer").addAccountKey(accounts.delegated);
	const bufferAddress = try bufferSeeds.findProgramAddress(ownerKey);
	if (!bufferAddress.key.equals(accounts.buffer.key())) { return Result.err(ProgramError.invalidSeeds()); }
	const dataLength = accounts.delegated.dataLength();
	const _bufferCreated = try createAccount(accounts.payer, accounts.buffer, 0, dataLength, ownerKey, bufferSeeds.withBump(bufferAddress.bump));
	const _copied = try accounts.buffer.data().copyFrom(accounts.delegated.data());
	accounts.delegated.data().fillWith(0);

	const signer = seeds.withBump(bump);
	if (!accounts.delegated.owner().equals(Pubkey.systemProgram())) {
		accounts.delegated.assign(Pubkey.systemProgram());
	}
	const _assigned = try assignTo(accounts.delegated, Pubkey.delegationProgram(), signer);

	const seedCount = seeds.seedCount();
	const instruction = Instruction.forProgram(Pubkey.delegationProgram(), 7, 49 + 36 * seedCount);
	instruction.addWritableSigner(accounts.payer);
	instruction.addWritableSigner(accounts.delegated);
	instruction.addReadonly(accounts.ownerProgram);
	instruction.addWritable(accounts.buffer);
	instruction.addWritable(accounts.delegationRecord);
	instruction.addWritable(accounts.delegationMetadata);
	instruction.addReadonly(accounts.systemProgram);
	instruction.appendU64(0);
	instruction.appendU32(config.commitFrequencyMs);
	instruction.appendU32(seedCount as uint32);
	for (let index: uint64 = 0; index < seedCount; index++) {
		const seed = seeds.seedAt(index);
		instruction.appendU32(seed.length as uint32);
		instruction.appendBytes(seed);
	}
	if (config.validator.isZero()) {
		instruction.appendU8(0);
	} else {
		instruction.appendU8(1);
		instruction.appendPubkey(config.validator);
	}
	const _delegated = try instruction.invokeSigned(signer);
	return closeBuffer(accounts.payer, accounts.buffer);
}

function scheduleCommit(
	payer: Account,
	committed: Readonly<Span<Account>>,
	magicContextAccount: Account,
	feeVault: Account | null,
	discriminant: uint32,
): Result<uint64, ProgramError> {
	if (!payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const prefix: uint64 = feeVault === null ? 2 : 3;
	const instruction = Instruction.forProgram(
		Pubkey.magicProgram(),
		prefix + (committed.length as uint64),
		4,
	);
	instruction.addAccount(payer, payer.isWritable(), true);
	instruction.addWritable(magicContextAccount);
	if (feeVault !== null) { instruction.addWritable(feeVault); }
	for (const account of committed) {
		instruction.addAccount(account, account.isWritable(), account.isSigner());
	}
	instruction.appendU32(discriminant);
	return instruction.invoke();
}

export function commit(payer: Account, committed: Account, magicContextAccount: Account): Result<uint64, ProgramError> {
	const accounts: Account[1] = [committed];
	return scheduleCommit(payer, accounts, magicContextAccount, null, 1);
}

export function commit(
	payer: Account,
	committed: Readonly<Span<Account>>,
	magicContextAccount: Account,
): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, null, 1);
}

export function commit(
	payer: Account,
	committed: Readonly<Span<Account>>,
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
	committed: Readonly<Span<Account>>,
	magicContextAccount: Account,
): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, null, 2);
}

export function commitAndUndelegate(
	payer: Account,
	committed: Readonly<Span<Account>>,
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

function parseSeeds(data: Bytes, start: uint64): Result<Seeds, ProgramError> {
	const count = try data.readU32(start);
	if (count == 0 || count > 16) { return Result.err(ProgramError.invalidInstructionData()); }
	const seeds = Seeds.empty(count as uint64);
	let offset = start + 4;
	for (let index: uint32 = 0; index < count; index++) {
		const length = try data.readU32(offset);
		const view = try data.range(offset + 4, length as uint64);
		seeds.addBytes(view);
		offset = offset + 4 + (length as uint64);
	}
	if (offset != data.length) { return Result.err(ProgramError.invalidInstructionData()); }
	return Result.ok(seeds);
}

export function undelegate(delegated: Account, buffer: Account, payer: Account, ownerProgramId: Pubkey, callbackData: Bytes): Result<uint64, ProgramError> {
	if (!buffer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	if (!buffer.owner().equals(Pubkey.delegationProgram())) { return Result.err(ProgramError.invalidAccountOwner()); }
	const canonical = try Seeds.empty(2).addText("undelegate-buffer").addAccountKey(delegated).findProgramAddress(Pubkey.delegationProgram());
	if (!canonical.key.equals(buffer.key())) { return Result.err(ProgramError.invalidSeeds()); }
	const seeds = try parseSeeds(callbackData, 8);
	const expected = try seeds.findProgramAddress(ownerProgramId);
	if (!expected.key.equals(delegated.key())) { return Result.err(ProgramError.invalidSeeds()); }
	const _created = try createProgramAccount(payer, delegated, buffer.dataLength(), ownerProgramId, seeds.withBump(expected.bump));
	return delegated.data().copyFrom(buffer.data());
}

function scheduled(
	payer: Account,
	taskId: uint64,
	intervalMillis: uint64,
	iterations: uint64,
	task: Instruction,
): Result<uint64, ProgramError> {
	if (!payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const instruction = Instruction.forProgram(
		Pubkey.magicProgram(),
		1 + task.accountLength(),
		36 + task.encodedLength(),
	);
	instruction.addWritableSigner(payer);
	instruction.addAccountsOf(task);
	instruction.appendU32(6);
	instruction.appendU64(taskId);
	instruction.appendU64(intervalMillis);
	instruction.appendU64(iterations);
	instruction.appendU64(1);
	instruction.appendInstruction(task);
	return instruction.invoke();
}

export function scheduleTask(payer: Account, taskId: uint64, intervalMillis: uint64, iterations: uint64, target: Account, targetData: Bytes, targetProgram: Pubkey): Result<uint64, ProgramError> {
	const task = Instruction.forProgram(targetProgram, 1, targetData.length);
	task.addWritable(target);
	task.appendBytes(targetData);
	return scheduled(payer, taskId, intervalMillis, iterations, task);
}

export function scheduleTask(
	payer: Account,
	taskId: uint64,
	intervalMillis: uint64,
	iterations: uint64,
	task: Instruction,
): Result<uint64, ProgramError> {
	return scheduled(payer, taskId, intervalMillis, iterations, task);
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

	function petSeeds(): Seeds {
		return Seeds.empty(1).addText("pet");
	}

	function petKey(): Pubkey {
		const derived = petSeeds().findProgramAddress(programKey());
		if (derived.ok) { return derived.value.key; }
		return Pubkey.zero();
	}

	function delegateStep(): Result<uint64, ProgramError> {
		const pinned = try instructionData().readU8(0);
		const derived = try petSeeds().findProgramAddress(programId());
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
		return delegate(delegation, petSeeds(), derived.bump, config);
	}

	function delegateEntry(): void {
		const result = delegateStep();
		if (!result.ok) { failWith(result.error); }
	}

	function delegationAccounts(): HostAccount[] {
		let buffer = Pubkey.zero();
		const found = Seeds.empty(2)
			.addText("buffer")
			.addPubkey(petKey())
			.findProgramAddress(programKey());
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
		const found = Seeds.empty(2)
			.addText("undelegate-buffer")
			.addPubkey(petKey())
			.findProgramAddress(Pubkey.delegationProgram());
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
