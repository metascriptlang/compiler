import {
	Account,
	AccountMeta,
	InstructionAccount,
	programId,
	putBool,
	putPubkey,
	putSpan,
	putU32,
	putU64,
} from "./core";
import { ProgramError } from "./error";
import { invokeSigned } from "./invoke";
import { findProgramAddress, findProgramAddressOf, signed } from "./macro";
import { Pubkey, pubkeyOf } from "./pubkey";
import { SeedSlice, SignerSeeds, seedBytes, seedText, signerOf } from "./seed";

when (testBuild) {
	import { account, failWith, instructionData, putBytes } from "./core";
	import { HostAccount, invocations, run, signerIs, textBytes } from "./host";
}

export struct RandomnessRequest {
	payer: Account;
	programIdentity: Account;
	oracleQueue: Account;
	systemProgram: Account;
	slotHashes: Account;
}

export const VRF_PROGRAM_ID: Pubkey = pubkeyOf("Vrf1RNUjXmQGjmQrQLvJHs9SNkvDJEsRVFPkfSQUwGz");

export const VRF_EPHEMERAL_QUEUE_ID: Pubkey = pubkeyOf("5hBR571xnXppuCPveTrctfTU7tJLSN94nq7kv7FRK5Tc");

export const VRF_BASE_QUEUE_ID: Pubkey = pubkeyOf("Cuj97ggrhhidhbu39TijNVqE74xvKJ69gDervRUXAxGh");

function requested(
	storage: Span<uint8>,
	callerSeed: Pubkey,
	callbackDiscriminator: uint64,
	callbackAccounts: Readonly<Span<AccountMeta>>,
	callbackArguments: Readonly<Span<uint8>>,
): uint64 {
	let length = putU64(storage, 0, 10);
	length = putPubkey(storage, length, callerSeed);
	length = putPubkey(storage, length, programId());
	length = putU32(storage, length, 8);
	length = putU64(storage, length, callbackDiscriminator);
	length = putU32(storage, length, callbackAccounts.length as uint32);
	for (const meta of callbackAccounts) {
		length = putPubkey(storage, length, meta.key);
		length = putBool(storage, length, meta.signer);
		length = putBool(storage, length, meta.writable);
	}
	length = putU32(storage, length, callbackArguments.length as uint32);
	return putSpan(storage, length, callbackArguments);
}

@noinline export function requestRandomness(
	accounts: RandomnessRequest,
	callerSeed: Pubkey,
	callbackDiscriminator: uint64,
	callbackAccounts: Readonly<Span<AccountMeta>>,
	callbackArguments: Readonly<Span<uint8>>,
	payerSigners: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const identity = try findProgramAddress(["identity"]);
	if (!identity.key.equals(accounts.programIdentity.key())) { return Result.err(ProgramError.invalidSeeds()); }
	if (payerSigners.length > 1) { return Result.err(ProgramError.invalidArgument()); }
	let storage: uint8[1024] = [];
	const length = requested(storage, callerSeed, callbackDiscriminator, callbackAccounts, callbackArguments);
	if (length > (storage.length as uint64)) { return Result.err(ProgramError.invalidInstructionData()); }
	const bump: uint8[1] = [identity.bump];
	const identitySeeds: SeedSlice[2] = [seedText("identity"), seedBytes(bump)];
	let both: SignerSeeds[2] = [signerOf(identitySeeds), signerOf(identitySeeds)];
	if (payerSigners.length == 1) { both[1] = payerSigners[0]; }
	return invokeSigned(
		VRF_PROGRAM_ID,
		[
			InstructionAccount.writableSigner(accounts.payer),
			InstructionAccount.readonlySigner(accounts.programIdentity),
			InstructionAccount.writable(accounts.oracleQueue),
			InstructionAccount.readonly(accounts.systemProgram),
			InstructionAccount.readonly(accounts.slotHashes),
		],
		storage,
		length,
		both[0..(1 + payerSigners.length)],
	);
}

export function requestRandomness(
	accounts: RandomnessRequest,
	callerSeed: Pubkey,
	callbackDiscriminator: uint64,
	callbackAccount: Account,
	callbackArguments: Readonly<Span<uint8>>,
	payerSigners: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	const callbackAccounts: AccountMeta[1] = [AccountMeta.writable(callbackAccount.key())];
	return requestRandomness(
		accounts,
		callerSeed,
		callbackDiscriminator,
		callbackAccounts,
		callbackArguments,
		payerSigners,
	);
}

export function verifyVrfCallback(identity: Account): Result<uint64, ProgramError> {
	if (!identity.isSigner()) { return Result.err(ProgramError.missingRequiredSignature()); }
	const scoped = try findProgramAddressOf(VRF_PROGRAM_ID, ["identity", programId()]);
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
			owner: Pubkey.zero(),
			lamports: 1000,
			data: [],
			signer: signer,
			writable: writable,
			executable: false,
		};
	}

	function identityOf(program: Pubkey): Pubkey {
		const found = findProgramAddressOf(program, ["identity"]);
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	function scopedIdentity(): Pubkey {
		const found = findProgramAddressOf(VRF_PROGRAM_ID, ["identity", programKey()]);
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	function requestAccounts(identity: Pubkey): HostAccount[] {
		return [
			holder(keyOf(1), true, true),
			holder(identity, false, false),
			holder(VRF_EPHEMERAL_QUEUE_ID, false, true),
			holder(Pubkey.zero(), false, false),
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
		const tail = try data.range(1, data.length - 1);
		let relay: uint8[1024] = [];
		const kept = putBytes(relay, 0, tail) as int32;
		if (op == 5 || op == 6) {
			const callbackAccount = try account(5);
			const args5 = relay[0..2];
			if (op == 5) {
				const sent = try requestRandomness(request, keyOf(99), callback, callbackAccount, args5);
				return Result.ok(sent);
			}
			const bump = try vrfPayerBump();
			const paid = try signed(
				requestRandomness(request, keyOf(99), callback, callbackAccount, args5),
				["vrf-payer", [bump]],
			);
			return Result.ok(paid);
		}
		if (op >= 3) {
			return requestRandomness(request, keyOf(99), callback, [], relay[0..kept]);
		}
		const args = relay[0..2];
		if (op == 0) {
			const callbackAccount = try account(5);
			const one: AccountMeta[1] = [AccountMeta.writable(callbackAccount.key())];
			return requestRandomness(request, keyOf(99), callback, one, args);
		}
		const metas: AccountMeta[3] = [
			AccountMeta.writable(keyOf(11)),
			AccountMeta.readonly(keyOf(12)),
			AccountMeta.writable(keyOf(13)),
		];
		if (op == 2) {
			const bump = try vrfPayerBump();
			return signed(
				requestRandomness(request, keyOf(99), callback, metas, args),
				["vrf-payer", [bump]],
			);
		}
		return requestRandomness(request, keyOf(99), callback, metas, args);
	}

	function vrfPayerBump(): Result<uint8, ProgramError> {
		const found = try findProgramAddress(["vrf-payer"]);
		return Result.ok(found.bump);
	}

	function vrfPayerKey(): Pubkey {
		const found = findProgramAddressOf(programKey(), ["vrf-payer"]);
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
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

	// ephemeral-vrf-sdk-0.4.1/src/consts.rs:4,7,10.
	test "the VRF ids are the ones the SDK declares" {
		assert VRF_PROGRAM_ID.toBase58() == "Vrf1RNUjXmQGjmQrQLvJHs9SNkvDJEsRVFPkfSQUwGz";
		assert VRF_BASE_QUEUE_ID.toBase58() == "Cuj97ggrhhidhbu39TijNVqE74xvKJ69gDervRUXAxGh";
		assert VRF_EPHEMERAL_QUEUE_ID.toBase58() == "5hBR571xnXppuCPveTrctfTU7tJLSN94nq7kv7FRK5Tc";
	}

	test "requestRandomness sends the scoped request with the program identity signing" {
		assert requestRun(requestAccounts(identityOf(programKey())), 0) == 0;
		const sent = invocations()[0];
		assert sent.program.equals(VRF_PROGRAM_ID) && sent.signers == 1;
		const identity = findProgramAddressOf(programKey(), ["identity"]);
		assert identity.ok;
		if (identity.ok) { assert signerIs(sent, 0, [textBytes("identity"), [identity.value.bump]]); }
		assert sent.accounts.length == 5;
		assert sent.accounts[0].key.equals(keyOf(1));
		assert sent.accounts[0].signer && sent.accounts[0].writable;
		assert sent.accounts[1].key.equals(identityOf(programKey()));
		assert sent.accounts[1].signer && !sent.accounts[1].writable;
		assert sent.accounts[2].key.equals(VRF_EPHEMERAL_QUEUE_ID) && sent.accounts[2].writable;
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

	test "a program PDA pays for the request, signing next to the program identity" {
		const accounts = requestAccounts(identityOf(programKey()));
		accounts[0] = holder(vrfPayerKey(), false, true);
		assert requestRun(accounts, 2) == 0;
		const sent = invocations()[0];
		assert sent.signers == 2;
		const identity = findProgramAddressOf(programKey(), ["identity"]);
		const payer = findProgramAddressOf(programKey(), ["vrf-payer"]);
		assert identity.ok && payer.ok;
		if (identity.ok && payer.ok) {
			assert signerIs(sent, 0, [textBytes("identity"), [identity.value.bump]]);
			assert signerIs(sent, 1, [textBytes("vrf-payer"), [payer.value.bump]]);
		}
		assert sent.accounts[0].key.equals(vrfPayerKey());
		assert sent.accounts[0].signer && sent.accounts[0].writable;
		assert sent.accounts[1].key.equals(identityOf(programKey())) && sent.accounts[1].signer;
		assert u32At(sent.data, 84) == 3;
	}

	function sameInvocation(left: uint8[], right: uint8[]): boolean {
		if (left.length != right.length) { return false; }
		for (let index = 0; index < left.length; index++) {
			if (left[index] != right[index]) { return false; }
		}
		return true;
	}

	test "the single callback account form sends the bytes of a one-account list, under try" {
		assert requestRun(requestAccounts(identityOf(programKey())), 0) == 0;
		const listed = invocations()[0];
		assert requestRun(requestAccounts(identityOf(programKey())), 5) == 0;
		const single = invocations()[0];
		assert single.program.equals(listed.program) && single.signers == 1;
		assert single.accounts.length == listed.accounts.length;
		for (let index = 0; index < listed.accounts.length; index++) {
			assert single.accounts[index].key.equals(listed.accounts[index].key);
			assert single.accounts[index].signer == listed.accounts[index].signer;
			assert single.accounts[index].writable == listed.accounts[index].writable;
		}
		assert sameInvocation(single.data, listed.data);
		assert u32At(single.data, 84) == 1 && keyAt(single.data, 88).equals(keyOf(5));
		assert single.data[120] == 0 && single.data[121] == 1;
	}

	test "the single callback account form signs next to a payer PDA, under signed and try" {
		const accounts = requestAccounts(identityOf(programKey()));
		accounts[0] = holder(vrfPayerKey(), false, true);
		assert requestRun(accounts, 6) == 0;
		const sent = invocations()[0];
		assert sent.signers == 2;
		const payer = findProgramAddressOf(programKey(), ["vrf-payer"]);
		assert payer.ok;
		if (payer.ok) { assert signerIs(sent, 1, [textBytes("vrf-payer"), [payer.value.bump]]); }
		assert u32At(sent.data, 84) == 1 && keyAt(sent.data, 88).equals(keyOf(5));
	}

	function requestWith(length: int32): uint64 {
		const input: uint8[] = [3];
		for (let index = 0; index < length; index++) { input.push(0xcc); }
		return run(programKey(), requestAccounts(identityOf(programKey())), input, requestEntry).result;
	}

	test "a request whose bytes do not fit the 1024-byte buffer is refused before it is sent" {
		assert requestWith(1024 - 92) == 0;
		const sent = invocations()[0];
		assert sent.data.length == 1024;
		assert requestWith(1024 - 92 + 1) == ProgramError.invalidInstructionData().code;
		assert invocations().length == 0;
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
		const global = holder(identityOf(VRF_PROGRAM_ID), true, false);
		assert callbackRun(global) == ProgramError.incorrectAuthority().code;
	}
}
