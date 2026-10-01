import {
	Account,
	AccountMeta,
	Bytes,
	Instruction,
	ProgramError,
	Pubkey,
	pubkeyOf,
	Seeds,
	programId,
} from "./index";

export struct RandomnessRequest {
	payer: Account;
	programIdentity: Account;
	oracleQueue: Account;
	systemProgram: Account;
	slotHashes: Account;
}

export function vrfProgram(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("Vrf1RNUjXmQGjmQrQLvJHs9SNkvDJEsRVFPkfSQUwGz"); };
}

export function vrfEphemeralQueue(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("5hBR571xnXppuCPveTrctfTU7tJLSN94nq7kv7FRK5Tc"); };
}

export function vrfBaseQueue(this typeof Pubkey): Pubkey {
	return @comptime { return pubkeyOf("Cuj97ggrhhidhbu39TijNVqE74xvKJ69gDervRUXAxGh"); };
}

function requested(
	accounts: RandomnessRequest,
	callerSeed: Pubkey,
	callbackDiscriminator: uint64,
	callbackAccounts: Span<AccountMeta>,
	callbackArguments: Bytes,
): Result<uint64, ProgramError> {
	const identity = try Seeds.empty(1).addText("identity").findProgramAddress(programId());
	if (!identity.key.equals(accounts.programIdentity.key())) { return Result.err(ProgramError.invalidSeeds()); }
	const metaCount = callbackAccounts.length as uint64;
	const instruction = Instruction.forProgram(
		Pubkey.vrfProgram(),
		5,
		92 + 34 * metaCount + callbackArguments.length,
	);
	instruction.addWritableSigner(accounts.payer);
	instruction.addReadonlySigner(accounts.programIdentity);
	instruction.addWritable(accounts.oracleQueue);
	instruction.addReadonly(accounts.systemProgram);
	instruction.addReadonly(accounts.slotHashes);
	instruction.appendU64(10);
	instruction.appendPubkey(callerSeed);
	instruction.appendPubkey(programId());
	instruction.appendU32(8);
	instruction.appendU64(callbackDiscriminator);
	instruction.appendU32(metaCount as uint32);
	for (const meta of callbackAccounts) {
		instruction.appendAccountMeta(meta);
	}
	instruction.appendU32(callbackArguments.length as uint32);
	instruction.appendBytes(callbackArguments);
	return instruction.invokeSigned(Seeds.empty(2).addText("identity").addU8(identity.bump));
}

export function requestRandomness(accounts: RandomnessRequest, callerSeed: Pubkey, callbackDiscriminator: uint64, callbackAccount: Account, callbackArguments: Bytes): Result<uint64, ProgramError> {
	const callbackAccounts: AccountMeta[1] = [AccountMeta.writable(callbackAccount.key())];
	return requested(
		accounts,
		callerSeed,
		callbackDiscriminator,
		callbackAccounts,
		callbackArguments,
	);
}

export function requestRandomness(
	accounts: RandomnessRequest,
	callerSeed: Pubkey,
	callbackDiscriminator: uint64,
	callbackAccounts: Span<AccountMeta>,
	callbackArguments: Bytes,
): Result<uint64, ProgramError> {
	return requested(
		accounts,
		callerSeed,
		callbackDiscriminator,
		callbackAccounts,
		callbackArguments,
	);
}

export function verifyVrfCallback(identity: Account): Result<uint64, ProgramError> {
	if (!identity.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const scoped = try Seeds.empty(2).addText("identity").addPubkey(programId()).findProgramAddress(Pubkey.vrfProgram());
	if (!scoped.key.equals(identity.key())) { return Result.err(ProgramError.incorrectAuthority()); }
	return Result.ok(0);
}
