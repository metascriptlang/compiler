import {
	Account,
	DELEGATION_PROGRAM_ID,
	InstructionAccount,
	assignTo,
	programId,
	createAccountAllowPrefund,
	putPubkey,
	putU32,
	putU64,
	putU8,
} from "./core";
import { putAddress } from "./buffer";
import { invokeSigned } from "./invoke";
import { ProgramError } from "./error";
import { Pubkey } from "./pubkey";
import {
	SeedSlice,
	SeedTable,
	SignerSeeds,
	bytesAddress,
	fillWithBump,
	findExpected,
	seedBytes,
	seedKey,
	seedText,
	signerOf,
	signerOfBumped,
	tableAddress,
} from "./seed";

// magicblock delegation-program src/processor/fast/delegate.rs:160-204 takes 1 to 8 seeds.
export const DELEGATION_MAX_SEEDS: uint64 = 8;

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
	buffer.assign(Pubkey.zero());
	return Result.ok(reclaimed);
}

export function delegateAt(
	accounts: DelegationAccounts,
	seeds: Readonly<Span<SeedSlice>>,
	bump: uint8,
	config: DelegationConfig,
): Result<uint64, ProgramError> {
	if (!accounts.payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const seedCount = seeds.length as uint64;
	if (seedCount == 0 || seedCount > DELEGATION_MAX_SEEDS) { return Result.err(ProgramError.maxSeedLengthExceeded()); }
	const ownerKey = accounts.ownerProgram.key();
	if (ownerKey != programId()) { return Result.err(ProgramError.incorrectProgramId()); }
	if (!accounts.delegated.isOwnedBy(ownerKey) && !accounts.delegated.isOwnedBy(Pubkey.zero())) {
		return Result.err(ProgramError.accountOwnedByWrongProgram());
	}
	const bufferSeeds: SeedSlice[2] = [seedText("buffer"), seedKey(accounts.delegated.keyAddress())];
	const bufferBump: uint8[1] = [try findExpected(bufferSeeds, bytesAddress(ownerKey.bytes), accounts.buffer.keyAddress())];
	let table: SeedTable = { slices: [], bump: [0], count: 0 };
	if (!fillWithBump(table, tableAddress(seeds), seedCount, bump)) {
		return Result.err(ProgramError.maxSeedLengthExceeded());
	}

	// A seed may point into the delegated account's data, which is zeroed below: sign with the copy the args carry.
	let storage: uint8[625] = [];
	let length = putU64(storage, 0, 0);
	length = putU32(storage, length, config.commitFrequencyMs);
	length = putU32(storage, length, seedCount as uint32);
	for (let index: uint64 = 0; index < seedCount; index++) {
		const seed = table.slices[index];
		length = putU32(storage, length, seed.length as uint32);
		table.slices[index] = { address: bytesAddress(storage) + length, length: seed.length };
		length = putAddress(storage, length, seed.address, seed.length);
	}
	if (config.validator.isZero()) {
		length = putU8(storage, length, 0);
	} else {
		length = putU8(storage, length, 1);
		length = putPubkey(storage, length, config.validator);
	}
	let signer: SignerSeeds[1] = [{ address: 0, length: 0 }];
	signerOfBumped(table, signer);

	const dataLength = accounts.delegated.dataLength();
	const bufferSigner: SeedSlice[3] = [bufferSeeds[0], bufferSeeds[1], seedBytes(bufferBump)];
	const bufferSigners: SignerSeeds[1] = [signerOf(bufferSigner)];
	const _bufferCreated = try createAccountAllowPrefund(
		accounts.payer,
		accounts.buffer,
		0,
		dataLength,
		bytesAddress(ownerKey.bytes),
		bufferSigners,
	);
	const _copied = try accounts.buffer.data().copyFrom(accounts.delegated.data());
	accounts.delegated.data().fillWith(0);

	if (!accounts.delegated.owner().equals(Pubkey.zero())) {
		accounts.delegated.assign(Pubkey.zero());
	}
	const _assigned = try assignTo(accounts.delegated, DELEGATION_PROGRAM_ID, signer);

	const _delegated = try invokeSigned(
		DELEGATION_PROGRAM_ID,
		[
			InstructionAccount.writableSigner(accounts.payer),
			InstructionAccount.writableSigner(accounts.delegated),
			InstructionAccount.readonly(accounts.ownerProgram),
			InstructionAccount.writable(accounts.buffer),
			InstructionAccount.writable(accounts.delegationRecord),
			InstructionAccount.writable(accounts.delegationMetadata),
			InstructionAccount.readonly(accounts.systemProgram),
		],
		storage,
		length,
		signer,
	);
	return closeBuffer(accounts.payer, accounts.buffer);
}
