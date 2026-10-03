import { Account, Bytes, Instruction, assignTo, createAccount } from "./core";
import { ProgramError } from "./error";
import { Pubkey, pubkeyOf } from "./pubkey";
import {
	SeedSlice,
	SeedTable,
	SignerSeeds,
	bytesAddress,
	fillWithBump,
	findAddress,
	seedBytes,
	seedKey,
	seedText,
	signerOf,
	signerOfBumped,
	tableAddress,
} from "./seed";

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

export function delegateAt(
	accounts: DelegationAccounts,
	seeds: Span<SeedSlice>,
	bump: uint8,
	config: DelegationConfig,
): Result<uint64, ProgramError> {
	if (!accounts.payer.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const ownerKey = accounts.ownerProgram.key();
	const bufferSeeds: SeedSlice[2] = [seedText("buffer"), seedKey(accounts.delegated.keyAddress())];
	const bufferAddress = try findAddress(bufferSeeds, bytesAddress(ownerKey.bytes));
	if (!bufferAddress.key.equals(accounts.buffer.key())) { return Result.err(ProgramError.invalidSeeds()); }
	const seedCount = seeds.length as uint64;
	let table: SeedTable = { slices: [], bump: [0], count: 0 };
	if (!fillWithBump(table, tableAddress(seeds), seedCount, bump)) {
		return Result.err(ProgramError.maxSeedLengthExceeded());
	}
	let signer: SignerSeeds[1] = [{ address: 0, length: 0 }];
	signerOfBumped(table, signer);
	const dataLength = accounts.delegated.dataLength();
	const bufferBump: uint8[1] = [bufferAddress.bump];
	const bufferSigner: SeedSlice[3] = [bufferSeeds[0], bufferSeeds[1], seedBytes(bufferBump)];
	const bufferSigners: SignerSeeds[1] = [signerOf(bufferSigner)];
	const _bufferCreated = try createAccount(
		accounts.payer,
		accounts.buffer,
		0,
		dataLength,
		ownerKey,
		bufferSigners,
	);
	const _copied = try accounts.buffer.data().copyFrom(accounts.delegated.data());
	accounts.delegated.data().fillWith(0);

	if (!accounts.delegated.owner().equals(Pubkey.systemProgram())) {
		accounts.delegated.assign(Pubkey.systemProgram());
	}
	const _assigned = try assignTo(accounts.delegated, Pubkey.delegationProgram(), signer);

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
	for (const seed of seeds) {
		const written: Bytes = { address: seed.address, length: seed.length };
		instruction.appendU32(seed.length as uint32);
		instruction.appendBytes(written);
	}
	if (config.validator.isZero()) {
		instruction.appendU8(0);
	} else {
		instruction.appendU8(1);
		instruction.appendPubkey(config.validator);
	}
	const _delegated = try instruction.invoke(signer);
	return closeBuffer(accounts.payer, accounts.buffer);
}
