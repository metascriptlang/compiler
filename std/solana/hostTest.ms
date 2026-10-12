import { sha256 } from "std/crypto/sha256";
import { isEdwardsPoint } from "std/crypto/ed25519/point";
import { ProgramError } from "./error";
import { HostAccount, NOT_SIMULATED, REFUSED, logs, run } from "./host";
import { Pubkey, SYSTEM_PROGRAM_ID } from "./pubkey";
import {
	CREATE_ADDRESS,
	FIND_ADDRESS,
	FORWARD,
	FORWARD_AND_CARRY_ON,
	LOG_ACCOUNT_DATA,
	LOG_BYTES,
	NONE,
	OVERLAPPING_COPY,
	RETURN_DATA,
	VALIDATE_POINT,
	hostProgramEntry,
} from "./testHostProgram";

const SOL: uint64 = 1000000000;
const NO_ADDRESS: string = "Provided seeds do not result in a valid address";
const SEED_TOO_LONG: string = "Length of the seed is too long for address generation";

struct Passed {
	account: HostAccount;
	writable: boolean;
	signer: boolean;
}

struct Signing {
	signers: uint8;
	seeds: uint8;
	bytes: uint8[];
}

struct Outcome {
	result: uint64;
	fault: string;
	accounts: HostAccount[];
}

function keyOf(seed: uint8): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = seed;
	return key;
}

function programKey(): Pubkey { return keyOf(9); }

function holding(key: Pubkey, owner: Pubkey, lamports: uint64, data: uint8[] = []): HostAccount {
	return {
		key: key,
		owner: owner,
		lamports: lamports,
		data: data,
		signer: false,
		writable: true,
		executable: false,
	};
}

function wallet(seed: uint8): HostAccount {
	return { ...holding(keyOf(seed), SYSTEM_PROGRAM_ID, SOL), signer: true };
}

function held(account: HostAccount): Passed {
	return { account: account, writable: account.writable, signer: account.signer };
}

function flagged(account: HostAccount, writable: boolean, signer: boolean): Passed {
	return { account: account, writable: writable, signer: signer };
}

function unsigned(): Signing { return { signers: 0, seeds: 0, bytes: [] }; }

function seeded(bytes: uint8[], seeds: uint8 = 1, signers: uint8 = 1): Signing {
	return { signers: signers, seeds: seeds, bytes: bytes };
}

function derived(seed: uint8[]): Pubkey {
	let preimage: uint8[] = [];
	for (const byte of seed) { preimage.push(byte); }
	for (const byte of programKey().bytes) { preimage.push(byte); }
	for (const byte of "ProgramDerivedAddress".asBytes()) { preimage.push(byte); }
	return { bytes: sha256(preimage).bytes };
}

function seedWhere(onCurve: boolean, from: uint8): uint8[] {
	for (let counter = from as int32; counter < 256; counter++) {
		const seed: uint8[] = [115, 101, 101, 100, counter as uint8];
		if (isEdwardsPoint(derived(seed).bytes) == onCurve) { return seed; }
	}
	return [];
}

function zeros(count: int32): uint8[] {
	const bytes: uint8[] = [];
	for (let index = 0; index < count; index++) { bytes.push(0); }
	return bytes;
}

function sent(data: uint8[], accounts: HostAccount[] = []): Outcome {
	const outcome = run(programKey(), accounts, data, hostProgramEntry);
	return { result: outcome.result, fault: outcome.fault, accounts: accounts };
}

function forwarded(
	callee: Pubkey,
	passed: Passed[],
	instruction: uint8[],
	signing: Signing = unsigned(),
	op: uint8 = FORWARD,
): Outcome {
	const data: uint8[] = [op, NONE, passed.length as uint8];
	for (let index = 0; index < 4; index++) {
		const writable = index < passed.length && passed[index].writable ? 1 : 0;
		const signer = index < passed.length && passed[index].signer ? 2 : 0;
		data.push((writable + signer) as uint8);
	}
	data.push(signing.signers);
	data.push(signing.seeds);
	data.push(signing.bytes.length as uint8);
	for (const byte of signing.bytes) { data.push(byte); }
	for (const byte of instruction) { data.push(byte); }
	const program = { ...holding(callee, keyOf(0), 1), writable: false, executable: true };
	const accounts: HostAccount[] = [program];
	for (const entry of passed) { accounts.push(entry.account); }
	return sent(data, accounts);
}

function pushU64(bytes: uint8[], value: uint64): void {
	for (let index: uint64 = 0; index < 8; index++) {
		bytes.push(((value >> (index * 8)) & 255) as uint8);
	}
}

function transferOf(amount: uint64): uint8[] {
	const data: uint8[] = [2, 0, 0, 0];
	pushU64(data, amount);
	return data;
}

function refusedAs(outcome: Outcome, runtimeError: string): boolean {
	return outcome.result == REFUSED && outcome.fault.indexOf(`${runtimeError}: `) == 0;
}

function aborted(outcome: Outcome, because: string): boolean {
	return refusedAs(outcome, "ProgramFailedToComplete") && outcome.fault.indexOf(because) > 0;
}

function notSimulated(outcome: Outcome, what: string): boolean {
	return outcome.result == NOT_SIMULATED && outcome.fault.indexOf(what) > 0;
}

test "a program that carries on after a syscall the runtime aborts on does not read as a success" {
	assert sent([OVERLAPPING_COPY, 8]).result == 0;
	assert aborted(sent([OVERLAPPING_COPY, 4]), "Overlapping copy");
	assert aborted(sent([OVERLAPPING_COPY, 0]), "Overlapping copy");
	assert sent([RETURN_DATA, 0, 4]).result == 0;
	assert aborted(sent([RETURN_DATA, 1, 4]), "Return data too large");
	for (const op of [CREATE_ADDRESS, FIND_ADDRESS]) {
		assert sent([op, 0, 0]).result == 0;
		assert aborted(sent([op, 17, 1]), SEED_TOO_LONG);
		assert aborted(sent([op, 1, 33]), SEED_TOO_LONG);
	}
	assert sent([CREATE_ADDRESS, 16, 1]).result == 0;
	assert sent([FIND_ADDRESS, 1, 32]).result == 0;
}

test "a point is validated on the edwards curve, ristretto is not judged, an unknown curve aborts" {
	assert sent([VALIDATE_POINT, 0]).result == 0;
	assert logs()[0] == "Program log: 0x0, 0x0, 0x0, 0x0, 0x0";
	assert notSimulated(sent([VALIDATE_POINT, 1]), "the ristretto curve (1) is not simulated");
	for (const curve of [2, 3, 200]) {
		assert aborted(sent([VALIDATE_POINT, curve as uint8]), "InvalidAttribute");
	}
}

test "signer seeds the runtime refuses fail the run, whether the program returns or carries on" {
	const pdaSeed = seedWhere(false, 0);
	const curveSeed = seedWhere(true, 0);
	for (const callee of [keyOf(8), SYSTEM_PROGRAM_ID]) {
		const instruction = callee == SYSTEM_PROGRAM_ID ? transferOf(1) : [0 as uint8];
		for (const op of [FORWARD, FORWARD_AND_CARRY_ON]) {
			const signedBy = (signing: Signing): Outcome => {
				const passed = [held(wallet(1)), held(holding(keyOf(2), SYSTEM_PROGRAM_ID, SOL))];
				return forwarded(callee, passed, instruction, signing, op);
			};
			assert signedBy(unsigned()).result == 0;
			assert signedBy(seeded(pdaSeed)).result == 0;
			assert signedBy(seeded([], 0)).result == 0;
			assert signedBy(seeded(pdaSeed, 1, 16)).result == 0;
			assert aborted(signedBy(seeded(curveSeed)), NO_ADDRESS);
			assert aborted(signedBy(seeded(zeros(33))), SEED_TOO_LONG);
			assert aborted(signedBy(seeded(pdaSeed, 1, 17)), "Too many signers");
			assert aborted(signedBy(seeded([0], 17, 17)), "Too many signers");
		}
		for (const seed of [zeros(1), zeros(33)]) {
			const outcome = forwarded(callee, [held(wallet(1))], instruction, seeded(seed, 17));
			assert outcome.result == ProgramError.maxSeedLengthExceeded().code;
			assert outcome.fault == "";
		}
	}
}

test "a privilege the caller does not hold fails a call to a simulated program, carried on or not" {
	const pdaSeed = seedWhere(false, 0);
	const otherSeed = seedWhere(false, pdaSeed[4] + 1);
	for (const op of [FORWARD, FORWARD_AND_CARRY_ON]) {
		const payer = wallet(1);
		const stranger = holding(keyOf(2), SYSTEM_PROGRAM_ID, SOL);
		const pda = flagged(holding(derived(pdaSeed), SYSTEM_PROGRAM_ID, SOL), true, true);
		const readOnly = flagged({ ...stranger, writable: false }, true, false);
		const system = (passed: Passed[], signing: Signing): Outcome => {
			return forwarded(SYSTEM_PROGRAM_ID, passed, transferOf(1), signing, op);
		};
		assert system([pda, held(stranger)], seeded(pdaSeed)).result == 0;
		assert refusedAs(system([pda, held(stranger)], seeded(otherSeed)), "PrivilegeEscalation");
		assert refusedAs(system([pda, held(stranger)], unsigned()), "PrivilegeEscalation");
		assert refusedAs(system([held(payer), readOnly], unsigned()), "PrivilegeEscalation");
		assert aborted(system([held(payer), readOnly], seeded(seedWhere(true, 0))), NO_ADDRESS);
	}
}

test "an instruction the System simulator does not know fails the run as not simulated" {
	for (const op of [FORWARD, FORWARD_AND_CARRY_ON]) {
		const passed = [held(wallet(1))];
		const outcome = forwarded(SYSTEM_PROGRAM_ID, passed, [4, 0, 0, 0], unsigned(), op);
		assert notSimulated(outcome, "System program instruction 4 is not simulated");
	}
}

function linesStarting(prefix: string): int32 {
	let count = 0;
	for (const line of logs()) {
		if (line.indexOf(prefix) == 0) { count++; }
	}
	return count;
}

test "a log line is kept whole when it is UTF-8, a zero byte included, and aborts the program when not" {
	assert sent([LOG_BYTES, 0x68, 0xc3, 0xa9]).result == 0 && logs()[0] == "Program log: h\u{e9}";
	assert sent([LOG_BYTES]).result == 0 && logs()[0] == "Program log: ";
	assert sent([LOG_BYTES, 0xf4, 0x8f, 0xbf, 0xbf]).result == 0 && logs()[0].length > 13;
	assert sent([LOG_BYTES, 0x61, 0, 0x62]).result == 0;
	const line = logs()[0].asBytes();
	assert line.length == 16 && line[13] == 0x61 && line[14] == 0 && line[15] == 0x62;
	const refused: uint8[][] = [
		[0x61, 0xff],
		[0x61, 0xc3],
		[0x61, 0xed, 0xa0, 0x80],
		[0x61, 0xc0, 0xaf],
		[0x61, 0xf4, 0x90, 0x80, 0x80],
	];
	for (const bytes of refused) {
		const data: uint8[] = [LOG_BYTES];
		for (const byte of bytes) { data.push(byte); }
		assert aborted(sent(data), "sol_log_: the line is not valid UTF-8");
		assert linesStarting("Program log: a") == 0;
	}
}

test "the log keeps the lines that fit under 10,000 bytes and says once that it is truncated" {
	const text: uint8[] = [];
	for (let index = 0; index < 20000; index++) { text.push(0x61); }
	const invokeLine = `Program ${programKey().toBase58()} invoke [1]`.length;
	const cases: int32[][] = [
		[9000, 1, 0], [9900, 1, 1], [10000, 1, 1], [20000, 1, 1], [1000, 12, 1], [100, 120, 1],
	];
	for (const entry of cases) {
		const length = entry[0];
		const count = entry[1];
		const data: uint8[] = [
			LOG_ACCOUNT_DATA, (length & 255) as uint8, (length >> 8) as uint8, count as uint8, 0,
		];
		assert sent(data, [holding(keyOf(1), programKey(), SOL, text)]).result == 0;
		let fit = 0;
		while (fit < count && invokeLine + (fit + 1) * (13 + length) < 10000) { fit++; }
		assert linesStarting("Program log: aa") == fit;
		assert linesStarting("Log truncated") == entry[2];
	}
}
