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
} from "./core";

when (testBuild) {
	import { account, failWith, instructionData } from "./core";
	import { HostAccount, invocations, run } from "./host";
}

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
	const callbackAccounts: AccountMeta[1] = [AccountMeta.writableKey(callbackAccount.key())];
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

when (testBuild) {
	function keyOf(seed: uint8): Pubkey {
		let key = Pubkey.zero();
		key.bytes[0] = seed;
		return key;
	}

	function programKey(): Pubkey {
		return keyOf(9);
	}

	function holder(key: Pubkey, signer: boolean, writable: boolean): HostAccount {
		return {
			key: key,
			owner: Pubkey.systemProgram(),
			lamports: 1000,
			data: [],
			signer: signer,
			writable: writable,
			executable: false,
		};
	}

	function identityOf(program: Pubkey): Pubkey {
		const found = Seeds.empty(1).addText("identity").findProgramAddress(program);
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	function scopedIdentity(): Pubkey {
		const found = Seeds.empty(2)
			.addText("identity")
			.addPubkey(programKey())
			.findProgramAddress(Pubkey.vrfProgram());
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	function requestAccounts(identity: Pubkey): HostAccount[] {
		return [
			holder(keyOf(1), true, true),
			holder(identity, false, false),
			holder(Pubkey.vrfEphemeralQueue(), false, true),
			holder(Pubkey.systemProgram(), false, false),
			holder(keyOf(4), false, false),
			holder(keyOf(5), false, true),
		];
	}

	function requestStep(): Result<uint64, ProgramError> {
		const data = instructionData();
		const op = try data.readU8(0);
		const request: RandomnessRequest = {
			payer: try account(0),
			programIdentity: try account(1),
			oracleQueue: try account(2),
			systemProgram: try account(3),
			slotHashes: try account(4),
		};
		const callback: uint64 = 0x0807060504030201;
		const args = try data.range(1, 2);
		if (op == 0) {
			return requestRandomness(request, keyOf(99), callback, try account(5), args);
		}
		const metas: AccountMeta[3] = [
			AccountMeta.writableKey(keyOf(11)),
			AccountMeta.readonlyKey(keyOf(12)),
			AccountMeta.writableKey(keyOf(13)),
		];
		return requestRandomness(request, keyOf(99), callback, metas, args);
	}

	function requestEntry(): void {
		const result = requestStep();
		if (!result.ok) { failWith(result.error); }
	}

	function requestRun(accounts: HostAccount[], op: uint8): uint64 {
		const input: uint8[] = [op, 0xaa, 0xbb];
		return run(programKey(), accounts, input, requestEntry).result;
	}

	function keyAt(bytes: uint8[], offset: int32): Pubkey {
		let key = Pubkey.zero();
		for (let index = 0; index < 32; index++) { key.bytes[index] = bytes[offset + index]; }
		return key;
	}

	function u32At(bytes: uint8[], offset: int32): uint32 {
		let value: uint32 = 0;
		for (let index = 3; index >= 0; index--) {
			const byte: uint32 = bytes[offset + index] as uint32;
			value = (value << 8) | byte;
		}
		return value;
	}

	test "requestRandomness sends the scoped request with the program identity signing" {
		assert requestRun(requestAccounts(identityOf(programKey())), 0) == 0;
		const sent = invocations()[0];
		assert sent.program.equals(Pubkey.vrfProgram()) && sent.signers == 1;
		assert sent.accounts.length == 5;
		assert sent.accounts[0].key.equals(keyOf(1));
		assert sent.accounts[0].signer && sent.accounts[0].writable;
		assert sent.accounts[1].key.equals(identityOf(programKey()));
		assert sent.accounts[1].signer && !sent.accounts[1].writable;
		assert sent.accounts[2].key.equals(Pubkey.vrfEphemeralQueue()) && sent.accounts[2].writable;
		assert !sent.accounts[3].writable && !sent.accounts[4].writable;
		assert sent.data.length == 92 + 34 + 2;
		assert sent.data[0] == 10 && sent.data[1] == 0 && sent.data[7] == 0;
		assert keyAt(sent.data, 8).equals(keyOf(99));
		assert keyAt(sent.data, 40).equals(programKey());
		assert u32At(sent.data, 72) == 8;
		assert sent.data[76] == 1 && sent.data[83] == 8;
		assert u32At(sent.data, 84) == 1;
		assert keyAt(sent.data, 88).equals(keyOf(5));
		assert sent.data[120] == 0 && sent.data[121] == 1;
		assert u32At(sent.data, 122) == 2;
		assert sent.data[126] == 0xaa && sent.data[127] == 0xbb;
	}

	test "a callback account list is sent in order with each account's signer and writable bytes" {
		assert requestRun(requestAccounts(identityOf(programKey())), 1) == 0;
		const sent = invocations()[0];
		assert sent.data.length == 92 + 3 * 34 + 2;
		assert u32At(sent.data, 84) == 3;
		assert keyAt(sent.data, 88).equals(keyOf(11));
		assert sent.data[120] == 0 && sent.data[121] == 1;
		assert keyAt(sent.data, 122).equals(keyOf(12));
		assert sent.data[154] == 0 && sent.data[155] == 0;
		assert keyAt(sent.data, 156).equals(keyOf(13));
		assert sent.data[188] == 0 && sent.data[189] == 1;
		assert u32At(sent.data, 190) == 2 && sent.data[194] == 0xaa && sent.data[195] == 0xbb;
	}

	test "requestRandomness refuses an identity that is not the program's" {
		assert requestRun(requestAccounts(keyOf(2)), 0) == ProgramError.invalidSeeds().code;
		assert invocations().length == 0;
	}

	function callbackStep(): Result<uint64, ProgramError> {
		return verifyVrfCallback(try account(0));
	}

	function callbackEntry(): void {
		const result = callbackStep();
		if (!result.ok) { failWith(result.error); }
	}

	function callbackRun(identity: HostAccount): uint64 {
		const input: uint8[] = [];
		return run(programKey(), [identity], input, callbackEntry).result;
	}

	test "verifyVrfCallback accepts only the scoped VRF identity, signed" {
		assert callbackRun(holder(scopedIdentity(), true, false)) == 0;
		const unsigned = holder(scopedIdentity(), false, false);
		assert callbackRun(unsigned) == ProgramError.missingRequiredSignature().code;
		const global = holder(identityOf(Pubkey.vrfProgram()), true, false);
		assert callbackRun(global) == ProgramError.incorrectAuthority().code;
	}
}
