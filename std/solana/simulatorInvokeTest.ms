import { sha256 } from "std/crypto/sha256";
import { isEdwardsPoint } from "std/crypto/ed25519/point";
import { HostAccount, HostInvocation, HostRun, invocations, run, signerIs } from "./host";
import { Pubkey, SYSTEM_PROGRAM_ID } from "./pubkey";
import { ADD, CALL_AND_CARRY_ON, FORWARD, NONE, STEPS, SUBTRACT, hostProgramEntry } from "./testHostProgram";

const SOL: uint64 = 1000000000;
const MAX: uint64 = 0xffffffffffffffff;
const WRITABLE: uint8 = 1;
const SIGNER: uint8 = 2;

function keyOf(seed: uint8): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = seed;
	return key;
}

function programKey(): Pubkey { return keyOf(9); }

function holding(key: Pubkey, owner: Pubkey, lamports: uint64, writable: boolean, signer: boolean): HostAccount {
	return { key: key, owner: owner, lamports: lamports, data: [], signer: signer, writable: writable, executable: false };
}

function calleeAccount(): HostAccount {
	return { ...holding(keyOf(8), keyOf(0), 1, false, false), executable: true };
}

function derived(seed: uint8[]): Pubkey {
	const preimage: uint8[] = [];
	for (const byte of seed) { preimage.push(byte); }
	for (const byte of programKey().bytes) { preimage.push(byte); }
	for (const byte of "ProgramDerivedAddress".asBytes()) { preimage.push(byte); }
	return { bytes: sha256(preimage).bytes };
}

function offCurveSeed(): uint8[] {
	for (let counter = 0; counter < 256; counter++) {
		const seed: uint8[] = [115, 101, 101, 100, counter as uint8];
		if (!isEdwardsPoint(derived(seed).bytes)) { return seed; }
	}
	return [];
}

function forwardFlags(flags: uint8[], signers: uint8, seed: uint8[], instruction: uint8[]): uint8[] {
	const data: uint8[] = [FORWARD, NONE, flags.length as uint8];
	for (let index = 0; index < 4; index++) { data.push(index < flags.length ? flags[index] : 0); }
	data.push(signers);
	data.push(signers == 0 ? 0 : 1);
	data.push(seed.length as uint8);
	for (const byte of seed) { data.push(byte); }
	for (const byte of instruction) { data.push(byte); }
	return data;
}

function forwarded(accounts: HostAccount[], flags: uint8[], signers: uint8, seed: uint8[], instruction: uint8[]): HostInvocation[] {
	const held: HostAccount[] = [calleeAccount(), ...accounts];
	const _outcome = run(programKey(), held, forwardFlags(flags, signers, seed, instruction), hostProgramEntry);
	return invocations();
}

test "an invocation record keeps the callee, each meta's key and flags, the data and no signer seeds" {
	const accounts = [
		holding(keyOf(1), SYSTEM_PROGRAM_ID, SOL, true, true),
		holding(keyOf(2), SYSTEM_PROGRAM_ID, SOL, true, false),
		holding(keyOf(3), SYSTEM_PROGRAM_ID, SOL, false, true),
	];
	const calls = forwarded(accounts, [WRITABLE | SIGNER, WRITABLE, SIGNER], 0, [], [7, 8, 9]);
	assert calls.length == 1;
	assert calls[0].program.equals(keyOf(8));
	assert calls[0].accounts.length == 3;
	for (let index = 0; index < 3; index++) {
		assert calls[0].accounts[index].key.equals(accounts[index].key);
	}
	assert calls[0].accounts[0].writable && calls[0].accounts[0].signer;
	assert calls[0].accounts[1].writable && !calls[0].accounts[1].signer;
	assert !calls[0].accounts[2].writable && calls[0].accounts[2].signer;
	assert calls[0].data.length == 3 && calls[0].data[0] == 7 && calls[0].data[1] == 8 && calls[0].data[2] == 9;
	assert calls[0].signers == 0 && calls[0].signerSeeds.length == 0;
}

test "an invocation record with no metas and no data is empty, and keeps two signers' seed bytes" {
	const empty = forwarded([], [], 0, [], []);
	assert empty.length == 1 && empty[0].accounts.length == 0 && empty[0].data.length == 0;
	const seed = offCurveSeed();
	const pda = holding(derived(seed), SYSTEM_PROGRAM_ID, SOL, true, true);
	const signed = forwarded([pda], [WRITABLE | SIGNER], 2, seed, [1]);
	assert signed.length == 1 && signed[0].signers == 2 && signed[0].signerSeeds.length == 2;
	assert signerIs(signed[0], 0, [seed]) && signerIs(signed[0], 1, [seed]);
	assert !signerIs(signed[0], 0, [[1]]);
}

function pushU64(bytes: uint8[], value: uint64): void {
	for (let index: uint64 = 0; index < 8; index++) { bytes.push(((value >> (index * 8)) & 255) as uint8); }
}

function steps(): uint8[] { return [STEPS]; }

function call(program: uint8[], metas: uint8[][], instruction: uint8[]): void {
	program.push(CALL_AND_CARRY_ON);
	program.push(0);
	program.push(metas.length as uint8);
	for (const meta of metas) { program.push(meta[0]); program.push(meta[1]); }
	program.push(instruction.length as uint8);
	for (const byte of instruction) { program.push(byte); }
}

function adjust(program: uint8[], step: uint8, index: uint8, amount: uint64): void {
	program.push(step);
	program.push(index);
	pushU64(program, amount);
}

test "a record stays readable while later calls add records, and the next run starts with none" {
	const program = steps();
	call(program, [[1, WRITABLE | SIGNER]], [1, 2]);
	call(program, [], [9]);
	call(program, [[1, 0], [1, WRITABLE]], [3, 4, 5]);
	const accounts = [calleeAccount(), holding(keyOf(1), SYSTEM_PROGRAM_ID, SOL, true, true)];
	const outcome = run(programKey(), accounts, program, hostProgramEntry);
	assert outcome.result == 0 && outcome.fault == "";
	const calls = invocations();
	assert calls.length == 3;
	assert calls[0].accounts.length == 1 && calls[0].data.length == 2 && calls[0].data[1] == 2;
	assert calls[1].accounts.length == 0 && calls[1].data.length == 1 && calls[1].data[0] == 9;
	assert calls[2].accounts.length == 2 && calls[2].data.length == 3 && calls[2].data[2] == 5;
	assert calls[2].accounts[1].writable && !calls[2].accounts[0].writable;
	const again = steps();
	call(again, [], [6]);
	const second = run(programKey(), [calleeAccount()], again, hostProgramEntry);
	assert second.result == 0 && invocations().length == 1 && invocations()[0].data[0] == 6;
}

function owned(seed: uint8, lamports: uint64): HostAccount {
	return holding(keyOf(seed), programKey(), lamports, true, false);
}

function refusedUnbalanced(outcome: HostRun): boolean {
	return outcome.result == MAX && outcome.fault.indexOf("UnbalancedInstruction: ") == 0;
}

test "lamport sums that pass 64 bits balance, and a single credit or debit does not" {
	const moved = steps();
	adjust(moved, SUBTRACT, 0, 5);
	adjust(moved, ADD, 2, 5);
	const accounts = [owned(1, MAX), owned(2, MAX), owned(3, SOL)];
	const paid = run(programKey(), accounts, moved, hostProgramEntry);
	assert paid.result == 0 && paid.fault == "";
	assert accounts[0].lamports == MAX - 5 && accounts[1].lamports == MAX && accounts[2].lamports == SOL + 5;
	const credited = steps();
	adjust(credited, ADD, 2, 5);
	assert refusedUnbalanced(run(programKey(), [owned(1, MAX), owned(2, MAX), owned(3, SOL)], credited, hostProgramEntry));
	const debited = steps();
	adjust(debited, SUBTRACT, 1, 1);
	assert refusedUnbalanced(run(programKey(), [owned(1, MAX), owned(2, MAX), owned(3, SOL)], debited, hostProgramEntry));
}

test "an account passed twice is held once, so moving lamports between its two names balances" {
	const same = steps();
	adjust(same, ADD, 0, 5);
	adjust(same, SUBTRACT, 1, 5);
	const twice = run(programKey(), [owned(1, SOL), owned(1, SOL)], same, hostProgramEntry);
	assert twice.result == 0 && twice.fault == "";
	const lone = steps();
	adjust(lone, ADD, 1, 5);
	assert refusedUnbalanced(run(programKey(), [owned(1, SOL), owned(1, SOL), owned(2, SOL)], lone, hostProgramEntry));
}
