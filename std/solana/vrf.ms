import {
	Account,
	Bytes,
	Instruction,
	ProgramError,
	Pubkey,
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
	const word0: uint64 = 0x2bfdf1c877686407;
	const word1: uint64 = 0x195debea5cf3b99e;
	const word2: uint64 = 0x65b5075cc49ea23f;
	const word3: uint64 = 0x7ff7ac27b1a71bf2;
	const key: Pubkey = { word0: word0, word1: word1, word2: word2, word3: word3 };
	return key;
}

export function vrfEphemeralQueue(this typeof Pubkey): Pubkey {
	const word0: uint64 = 0xe72b76e2a0c1b945;
	const word1: uint64 = 0x1ad65f750aba11f0;
	const word2: uint64 = 0x59ed4b84b93d038f;
	const word3: uint64 = 0xa7ca288880053bf2;
	const key: Pubkey = { word0: word0, word1: word1, word2: word2, word3: word3 };
	return key;
}

export function vrfBaseQueue(this typeof Pubkey): Pubkey {
	const word0: uint64 = 0xb5447cdcf067f2b0;
	const word1: uint64 = 0x0d394dea4b36c402;
	const word2: uint64 = 0xca40e1dfb422917d;
	const word3: uint64 = 0xf28e0b1ce8f45b5d;
	const key: Pubkey = { word0: word0, word1: word1, word2: word2, word3: word3 };
	return key;
}

export function requestRandomness(accounts: RandomnessRequest, callerSeed: Pubkey, callbackDiscriminator: uint64, callbackAccount: Account, callbackArguments: Bytes): Result<uint64, ProgramError> {
	const identity = try Seeds.empty(1).addText("identity").findProgramAddress(programId());
	if (!identity.key.equals(accounts.programIdentity.key())) { return Result.err(ProgramError.invalidSeeds()); }
	const instruction = Instruction.forProgram(Pubkey.vrfProgram(), 5, 128 + callbackArguments.length);
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
	instruction.appendU32(1);
	instruction.appendPubkey(callbackAccount.key());
	instruction.appendU8(0);
	instruction.appendU8(1);
	instruction.appendU32(callbackArguments.length as uint32);
	instruction.appendBytes(callbackArguments);
	return instruction.invokeSigned(Seeds.empty(2).addText("identity").addU8(identity.bump));
}

export function verifyVrfCallback(identity: Account): Result<uint64, ProgramError> {
	if (!identity.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const scoped = try Seeds.empty(2).addText("identity").addPubkey(programId()).findProgramAddress(Pubkey.vrfProgram());
	if (!scoped.key.equals(identity.key())) { return Result.err(ProgramError.incorrectAuthority()); }
	return Result.ok(0);
}
