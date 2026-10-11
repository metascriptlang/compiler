import {
	Account,
	AccountMeta,
	InstructionAccount,
	putPubkey,
	putSpan,
	putU16,
	putU32,
	putU64,
	putU8,
} from "./core";
import { ProgramError } from "./error";
import { invokeSigned } from "./invoke";
import { findProgramAddressOf } from "./macro";
import { Pubkey, pubkeyOf } from "./pubkey";
import { SignerSeeds } from "./seed";

when (testBuild) {
	import { account, failWith, instructionData } from "./core";
	import { HostAccount, invocations, run, signerIs, textBytes } from "./host";
	import { findProgramAddress, signed } from "./macro";
	import { MAGIC_PROGRAM_ID } from "./magicblock";
}

export { MAGIC_VAULT_ID } from "./magicblock";

export const HYDRA_PROGRAM_ID: Pubkey = pubkeyOf("eHyd5BU8QffvHi4GnXwxrK4WpS7pM2x9UGKHBWii7mf");

export const CRANK_MAX_COMPUTE_UNITS: uint32 = 1_400_000;

export const CRANK_ONE_SHOT_INTERVAL_SLOTS: uint64 = 1_000_000_000;

const CREATE: uint8 = 0;
const CANCEL: uint8 = 2;
const WRITABLE_FLAG: uint8 = 2;
const CREATE_FIXED_BYTES: uint64 = 101;
const SCHEDULED_HEADER_BYTES: uint64 = 35;
const META_BYTES: uint64 = 33;
const REMAINING_OFFSET: uint64 = 80;

export struct CrankAccounts {
	sponsor: Account;
	crank: Account;
	magicVault: Account;
	magicProgram: Account;
}

export struct CrankSchedule {
	startSlot: uint64;
	intervalSlots: uint64;
	remaining: uint64;
	priorityTip: uint64;
	computeUnits: uint32;
}

export function once(this typeof CrankSchedule, startSlot: uint64): CrankSchedule {
	const schedule: CrankSchedule = {
		startSlot: startSlot,
		intervalSlots: CRANK_ONE_SHOT_INTERVAL_SLOTS,
		remaining: 1,
		priorityTip: 0,
		computeUnits: CRANK_MAX_COMPUTE_UNITS,
	};
	return schedule;
}

export function crankAddress(sponsor: Pubkey, seed: Pubkey): Result<Pubkey, ProgramError> {
	const found = try findProgramAddressOf(HYDRA_PROGRAM_ID, ["crank", sponsor, seed]);
	return Result.ok(found.key);
}

export function legacyCrankAddress(seed: Pubkey): Result<Pubkey, ProgramError> {
	const found = try findProgramAddressOf(HYDRA_PROGRAM_ID, ["crank", seed]);
	return Result.ok(found.key);
}

@noinline export function createCrank(
	accounts: CrankAccounts,
	seed: Pubkey,
	schedule: CrankSchedule,
	program: Pubkey,
	metas: Readonly<Span<AccountMeta>>,
	data: Readonly<Span<uint8>>,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	let storage: uint8[944] = [];
	const body = SCHEDULED_HEADER_BYTES + META_BYTES * (metas.length as uint64) + (data.length as uint64);
	if (CREATE_FIXED_BYTES + body > (storage.length as uint64)) { return Result.err(ProgramError.invalidArgument()); }
	for (const meta of metas) {
		if (meta.signer) { return Result.err(ProgramError.invalidArgument()); }
	}
	let at = putU8(storage, 0, CREATE);
	at = putPubkey(storage, at, seed);
	at = putPubkey(storage, at, accounts.sponsor.key());
	at = putU64(storage, at, schedule.startSlot);
	at = putU64(storage, at, schedule.intervalSlots);
	at = putU64(storage, at, schedule.remaining);
	at = putU64(storage, at, schedule.priorityTip);
	at = putU32(storage, at, schedule.computeUnits);
	at = putU8(storage, at, metas.length as uint8);
	at = putU16(storage, at, data.length as uint16);
	at = putPubkey(storage, at, program);
	for (const meta of metas) {
		at = putU8(storage, at, meta.writable ? WRITABLE_FLAG : 0);
		at = putPubkey(storage, at, meta.key);
	}
	at = putSpan(storage, at, data);
	return invokeSigned(
		HYDRA_PROGRAM_ID,
		[
			InstructionAccount.writableSigner(accounts.sponsor),
			InstructionAccount.writable(accounts.crank),
			InstructionAccount.writable(accounts.magicVault),
			InstructionAccount.readonly(accounts.magicProgram),
		],
		storage,
		at,
		signers,
	);
}

export function cancelCrank(
	accounts: CrankAccounts,
	signers: Readonly<Span<SignerSeeds>> = [],
): Result<uint64, ProgramError> {
	let storage: uint8[1] = [];
	const length = putU8(storage, 0, CANCEL);
	return invokeSigned(
		HYDRA_PROGRAM_ID,
		[
			InstructionAccount.writableSigner(accounts.sponsor),
			InstructionAccount.writable(accounts.crank),
			InstructionAccount.writable(accounts.sponsor),
			InstructionAccount.writable(accounts.magicVault),
			InstructionAccount.readonly(accounts.magicProgram),
		],
		storage,
		length,
		signers,
	);
}

export function crankSpent(crank: Account, sponsor: Pubkey): Result<boolean, ProgramError> {
	if (!crank.isOwnedBy(HYDRA_PROGRAM_ID) || crank.dataLength() < REMAINING_OFFSET + 8) { return Result.ok(false); }
	const data = crank.data();
	const authority = try data.readPubkey(0);
	const remaining = try data.readU64(REMAINING_OFFSET);
	return Result.ok(authority == sponsor && remaining == 0);
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

	function holder(key: Pubkey, owner: Pubkey, signer: boolean, data: uint8[]): HostAccount {
		return {
			key: key,
			owner: owner,
			lamports: 1000,
			data: data,
			signer: signer,
			writable: true,
			executable: false,
		};
	}

	function sameBytes(left: uint8[], right: uint8[]): boolean {
		if (left.length != right.length) { return false; }
		for (let index = 0; index < left.length; index++) {
			if (left[index] != right[index]) { return false; }
		}
		return true;
	}

	function keyBytes(key: Pubkey): uint8[] {
		const bytes: uint8[] = [];
		for (let index = 0; index < 32; index++) { bytes.push(key.bytes[index]); }
		return bytes;
	}

	function le(value: uint64, width: int32): uint8[] {
		const bytes: uint8[] = [];
		for (let index = 0; index < width; index++) { bytes.push(((value >> ((index * 8) as uint64)) & 255) as uint8); }
		return bytes;
	}

	function seedKey(): Pubkey {
		let key = Pubkey.zero();
		key.bytes[0] = 7;
		key.bytes[31] = 9;
		return key;
	}

	function sponsorPda(): Pubkey {
		const found = findProgramAddressOf(programKey(), ["sponsor"]);
		if (found.ok) { return found.value.key; }
		return Pubkey.zero();
	}

	function crankAccounts(): HostAccount[] {
		return [
			holder(keyOf(1), Pubkey.zero(), true, []),
			holder(keyOf(2), HYDRA_PROGRAM_ID, false, []),
			holder(MAGIC_VAULT_ID, Pubkey.zero(), false, []),
			holder(MAGIC_PROGRAM_ID, Pubkey.zero(), false, []),
		];
	}

	function crankHeld(): Result<CrankAccounts, ProgramError> {
		const held: CrankAccounts = {
			sponsor: try account(0),
			crank: try account(1),
			magicVault: try account(2),
			magicProgram: try account(3),
		};
		return Result.ok(held);
	}

	function joined(parts: uint8[][]): uint8[] {
		const bytes: uint8[] = [];
		for (const part of parts) {
			for (const byte of part) { bytes.push(byte); }
		}
		return bytes;
	}

	function wideMetas(count: int32): AccountMeta[] {
		const metas: AccountMeta[] = [];
		for (let index = 0; index < count; index++) { metas.push(AccountMeta.writable(keyOf((20 + index) as uint8))); }
		return metas;
	}

	function crankData(): uint8[] {
		return joined([le(0x0807060504030201, 8), le(5, 8)]);
	}

	// op 0: once, two accounts, 16 data bytes; 1: a repeating schedule with a tip and no accounts or data; 2: a signer meta;
	// 3: 25 accounts; 4: 24 accounts; 5: cancel; 6: once signed by a sponsor PDA; 7: cancel signed by it.
	function crankStep(): Result<uint64, ProgramError> {
		const op = try instructionData().readU8(0);
		const accounts = try crankHeld();
		const data = crankData();
		if (op == 0) {
			const metas: AccountMeta[2] = [AccountMeta.writable(keyOf(10)), AccountMeta.readonly(keyOf(11))];
			return createCrank(accounts, seedKey(), CrankSchedule.once(1000), keyOf(77), metas, data);
		}
		if (op == 1) {
			const schedule: CrankSchedule = {
				startSlot: 5,
				intervalSlots: 40,
				remaining: 0,
				priorityTip: 9,
				computeUnits: 200000,
			};
			return createCrank(accounts, seedKey(), schedule, keyOf(77), [], []);
		}
		if (op == 2) {
			const metas: AccountMeta[1] = [{ key: keyOf(10), writable: true, signer: true }];
			return createCrank(accounts, seedKey(), CrankSchedule.once(1000), keyOf(77), metas, data);
		}
		if (op == 3) {
			return createCrank(accounts, seedKey(), CrankSchedule.once(1000), keyOf(77), wideMetas(25), data);
		}
		if (op == 4) {
			return createCrank(accounts, seedKey(), CrankSchedule.once(1000), keyOf(77), wideMetas(24), data);
		}
		if (op == 5) { return cancelCrank(accounts); }
		const found = try findProgramAddress(["sponsor"]);
		const bump = found.bump;
		if (op == 6) {
			const metas: AccountMeta[1] = [AccountMeta.writable(keyOf(10))];
			return signed(
				createCrank(accounts, seedKey(), CrankSchedule.once(1000), keyOf(77), metas, data),
				["sponsor", [bump]],
			);
		}
		return signed(cancelCrank(accounts), ["sponsor", [bump]]);
	}

	function crankEntry(): void {
		const result = crankStep();
		if (!result.ok) { failWith(result.error); }
	}

	function crankRun(accounts: HostAccount[], op: uint8): uint64 {
		const input: uint8[] = [op];
		return run(programKey(), accounts, input, crankEntry).result;
	}

	// hydra-api/src/instruction.rs `CreateArgs::write_to`: disc, seed, authority, start, interval, remaining, tip, cu limit,
	// then per scheduled instruction num_accounts u8, data_len u16, program id, [flag, key] per account, data.
	test "the Hydra program is the ephemeral one, and its rent vault is the Magic vault" {
		assert HYDRA_PROGRAM_ID.toBase58() == "eHyd5BU8QffvHi4GnXwxrK4WpS7pM2x9UGKHBWii7mf";
		assert MAGIC_VAULT_ID.toBase58() == "MagicVau1t999999999999999999999999999999999";
	}

	test "createCrank sends Hydra the one-shot Create: the sponsor as authority, then the scheduled instruction" {
		assert crankRun(crankAccounts(), 0) == 0;
		const calls = invocations();
		assert calls.length == 1 && calls[0].signers == 0;
		const sent = calls[0];
		assert sent.program.equals(HYDRA_PROGRAM_ID);
		const expected = joined([
			[0], keyBytes(seedKey()), keyBytes(keyOf(1)),
			le(1000, 8), le(1000000000, 8), le(1, 8), le(0, 8), le(1400000, 4),
			[2], le(16, 2), keyBytes(keyOf(77)),
			[2], keyBytes(keyOf(10)),
			[0], keyBytes(keyOf(11)),
			crankData(),
		]);
		assert sameBytes(sent.data, expected);
		assert sent.data.length == 101 + 35 + 66 + 16;
		assert sent.accounts.length == 4;
		assert sent.accounts[0].key.equals(keyOf(1)) && sent.accounts[0].signer && sent.accounts[0].writable;
		assert sent.accounts[1].key.equals(keyOf(2)) && !sent.accounts[1].signer && sent.accounts[1].writable;
		assert sent.accounts[2].key.equals(MAGIC_VAULT_ID) && !sent.accounts[2].signer && sent.accounts[2].writable;
		assert sent.accounts[3].key.equals(MAGIC_PROGRAM_ID) && !sent.accounts[3].signer && !sent.accounts[3].writable;
	}

	test "a repeating schedule carries its own interval, count, tip and compute limit, and 0 accounts and 0 data bytes" {
		assert crankRun(crankAccounts(), 1) == 0;
		const sent = invocations()[0];
		const expected = joined([
			[0], keyBytes(seedKey()), keyBytes(keyOf(1)),
			le(5, 8), le(40, 8), le(0, 8), le(9, 8), le(200000, 4),
			[0], le(0, 2), keyBytes(keyOf(77)),
		]);
		assert sameBytes(sent.data, expected);
	}

	test "createCrank refuses a signer meta and a schedule that does not fit its buffer before it sends anything" {
		assert crankRun(crankAccounts(), 2) == ProgramError.invalidArgument().code;
		assert invocations().length == 0;
		assert crankRun(crankAccounts(), 3) == ProgramError.invalidArgument().code;
		assert invocations().length == 0;
		assert crankRun(crankAccounts(), 4) == 0;
		assert invocations()[0].data.length == 101 + 35 + 33 * 24 + 16;
	}

	test "cancelCrank sends Hydra the one byte Cancel: the sponsor signs and receives, then the crank, the vault, the Magic program" {
		assert crankRun(crankAccounts(), 5) == 0;
		const sent = invocations()[0];
		assert sent.program.equals(HYDRA_PROGRAM_ID) && sent.signers == 0;
		const expected: uint8[] = [2];
		assert sameBytes(sent.data, expected);
		assert sent.accounts.length == 5;
		assert sent.accounts[0].key.equals(keyOf(1)) && sent.accounts[0].signer && sent.accounts[0].writable;
		assert sent.accounts[1].key.equals(keyOf(2)) && sent.accounts[1].writable && !sent.accounts[1].signer;
		assert sent.accounts[2].key.equals(keyOf(1)) && sent.accounts[2].writable && !sent.accounts[2].signer;
		assert sent.accounts[3].key.equals(MAGIC_VAULT_ID) && sent.accounts[3].writable;
		assert sent.accounts[4].key.equals(MAGIC_PROGRAM_ID) && !sent.accounts[4].writable;
	}

	test "a sponsor PDA creates and cancels a crank by signing with its seeds" {
		const accounts = crankAccounts();
		accounts[0] = holder(sponsorPda(), Pubkey.zero(), false, []);
		const found = findProgramAddressOf(programKey(), ["sponsor"]);
		assert found.ok;
		if (!found.ok) { return; }
		const seeds = [textBytes("sponsor"), [found.value.bump]];
		assert crankRun(accounts, 6) == 0;
		const created = invocations()[0];
		assert created.signers == 1 && signerIs(created, 0, seeds);
		assert created.accounts[0].key.equals(sponsorPda()) && created.accounts[0].signer;
		assert sameBytes(created.data.slice(33, 65), keyBytes(sponsorPda()));
		assert crankRun(accounts, 7) == 0;
		const cancelled = invocations()[0];
		assert cancelled.signers == 1 && signerIs(cancelled, 0, seeds);
		assert cancelled.accounts[0].key.equals(sponsorPda()) && cancelled.accounts[2].key.equals(sponsorPda());
	}

	// Derived with @solana/kit getProgramDerivedAddress, seeds ["crank", sponsor, seed] and ["crank", seed].
	test "crankAddress binds the sponsor, the legacy address does not" {
		const bound = crankAddress(keyOf(1), seedKey());
		const legacy = legacyCrankAddress(seedKey());
		assert bound.ok && legacy.ok;
		if (bound.ok && legacy.ok) {
			assert bound.value.toBase58() == "4Rz6WEgibCeyw3brpMWzetMbGYdPNrsrZnYaFKandvKR";
			assert legacy.value.toBase58() == "H3ZSHsxbULSy9ubEwTDgV8niCtVftkHU7RH71aRq8y4W";
		}
		const other = crankAddress(keyOf(2), seedKey());
		assert other.ok && bound.ok;
		if (other.ok && bound.ok) { assert !other.value.equals(bound.value); }
	}

	function spentCrank(owner: Pubkey, authority: Pubkey, remaining: uint64, length: int32): HostAccount {
		const bytes = joined([keyBytes(authority), le(0, 48), le(remaining, 8)]);
		return holder(keyOf(2), owner, false, bytes.slice(0, length));
	}

	function spentStep(): Result<uint64, ProgramError> {
		const spent = try crankSpent(try account(0), keyOf(1));
		const marker: uint64 = spent ? 1 : 0;
		return Result.ok(marker);
	}

	function spentEntry(): void {
		const result = spentStep();
		if (!result.ok) { failWith(result.error); return; }
		if (result.value == 1) { failWith(ProgramError.custom(77)); }
	}

	function spentRun(account: HostAccount): uint64 {
		return run(programKey(), [account], [], spentEntry).result;
	}

	test "crankSpent is true for the sponsor's own crank with no executions left, and false otherwise" {
		const spent = ProgramError.custom(77).code;
		assert spentRun(spentCrank(HYDRA_PROGRAM_ID, keyOf(1), 0, 88)) == spent;
		assert spentRun(spentCrank(HYDRA_PROGRAM_ID, keyOf(1), 1, 88)) == 0;
		assert spentRun(spentCrank(HYDRA_PROGRAM_ID, keyOf(3), 0, 88)) == 0;
		assert spentRun(spentCrank(programKey(), keyOf(1), 0, 88)) == 0;
		assert spentRun(spentCrank(HYDRA_PROGRAM_ID, keyOf(1), 0, 87)) == 0;
	}
}
