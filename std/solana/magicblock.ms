import {
	Account,
	Bytes,
	Instruction,
	ProgramError,
	Pubkey,
	Seeds,
	assignTo,
	createAccount,
	createProgramAccount,
} from "./index";

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
	const word0: uint64 = 0xc03a57f2e100b7b5;
	const word1: uint64 = 0x97cf4a34012206cc;
	const word2: uint64 = 0x9819e58ceb0635b8;
	const word3: uint64 = 0x3ea78093187e62cc;
	const key: Pubkey = { word0: word0, word1: word1, word2: word2, word3: word3 };
	return key;
}

export function magicProgram(this typeof Pubkey): Pubkey {
	const word0: uint64 = 0x9570dab024b44505;
	const word1: uint64 = 0x28d777c3ded6b9ec;
	const word2: uint64 = 0xd612ea928ee7b691;
	const word3: uint64 = 0x403abbdf;
	const key: Pubkey = { word0: word0, word1: word1, word2: word2, word3: word3 };
	return key;
}

export function magicContext(this typeof Pubkey): Pubkey {
	const word0: uint64 = 0xbf28a5c424b44505;
	const word1: uint64 = 0x8e8252442f03b45f;
	const word2: uint64 = 0xf797dcd2c1ab38bb;
	const word3: uint64 = 0x8054948b3f;
	const key: Pubkey = { word0: word0, word1: word1, word2: word2, word3: word3 };
	return key;
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

function scheduleCommit(payer: Account, committed: Account, magicContextAccount: Account, discriminant: uint32): Result<uint64, ProgramError> {
	if (!payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const instruction = Instruction.forProgram(Pubkey.magicProgram(), 3, 4);
	instruction.addAccount(payer, payer.isWritable(), true);
	instruction.addWritable(magicContextAccount);
	instruction.addAccount(committed, committed.isWritable(), committed.isSigner());
	instruction.appendU32(discriminant);
	return instruction.invoke();
}

export function commit(payer: Account, committed: Account, magicContextAccount: Account): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, 1);
}

export function commitAndUndelegate(payer: Account, committed: Account, magicContextAccount: Account): Result<uint64, ProgramError> {
	return scheduleCommit(payer, committed, magicContextAccount, 2);
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

export function scheduleTask(payer: Account, taskId: uint64, intervalMillis: uint64, iterations: uint64, target: Account, targetData: Bytes, targetProgram: Pubkey): Result<uint64, ProgramError> {
	if (!payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const instruction = Instruction.forProgram(Pubkey.magicProgram(), 2, 128 + targetData.length);
	instruction.addWritableSigner(payer);
	instruction.addAccount(target, target.isWritable(), false);
	instruction.appendU32(6);
	instruction.appendU64(taskId);
	instruction.appendU64(intervalMillis);
	instruction.appendU64(iterations);
	instruction.appendU64(1);
	instruction.appendPubkey(targetProgram);
	instruction.appendU64(1);
	instruction.appendPubkey(target.key());
	instruction.appendU8(0);
	instruction.appendU8(1);
	instruction.appendU64(targetData.length);
	instruction.appendBytes(targetData);
	return instruction.invoke();
}
