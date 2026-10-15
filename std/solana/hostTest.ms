import { sha256 } from "std/crypto/sha256";
import { isEdwardsPoint } from "std/crypto/ed25519/point";
import { ProgramError } from "./error";
import { minimumBalance } from "./core";
import { HostAccount, NOT_SIMULATED, REFUSED, invocations, logs, run } from "./host";
import { Pubkey, SYSTEM_PROGRAM_ID } from "./pubkey";
import {
	ADD,
	ASSIGN,
	CALL,
	CALL_AND_CARRY_ON,
	CREATE_ADDRESS,
	FAIL,
	FIND_ADDRESS,
	FORWARD,
	FORWARD_AND_CARRY_ON,
	LOG,
	LOG_ACCOUNT_DATA,
	LOG_BYTES,
	NONE,
	OVERLAPPING_COPY,
	RESIZE,
	RETURN_DATA,
	STEPS,
	SUBTRACT,
	VALIDATE_POINT,
	WRITE,
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

function strange(passed: Passed[], signing: Signing, op: uint8): Outcome {
	const instruction: uint8[] = [0];
	return forwarded(keyOf(8), passed, instruction, signing, op);
}

test "a call to a program that is not simulated fails when it passes writable an account the instruction passed read-only" {
	const readOnly = { ...holding(keyOf(2), SYSTEM_PROGRAM_ID, SOL), writable: false };
	for (const op of [FORWARD, FORWARD_AND_CARRY_ON]) {
		assert strange([held(wallet(1)), held(readOnly)], unsigned(), op).result == 0;
		assert refusedAs(strange([held(wallet(1)), flagged(readOnly, true, false)], unsigned(), op), "PrivilegeEscalation");
	}
}

test "a call to a program that is not simulated fails when it passes as a signer an account that did not sign and no seeds derive" {
	const pdaSeed = seedWhere(false, 0);
	const pda = flagged(holding(derived(pdaSeed), SYSTEM_PROGRAM_ID, SOL), true, true);
	for (const op of [FORWARD, FORWARD_AND_CARRY_ON]) {
		assert strange([pda], seeded(pdaSeed), op).result == 0;
		assert refusedAs(strange([pda], unsigned(), op), "PrivilegeEscalation");
	}
}

test "a call to a program that is not simulated fails when its signer seeds derive another address than the signer it passes" {
	const pdaSeed = seedWhere(false, 0);
	const otherSeed = seedWhere(false, pdaSeed[4] + 1);
	const pda = flagged(holding(derived(pdaSeed), SYSTEM_PROGRAM_ID, SOL), true, true);
	for (const op of [FORWARD, FORWARD_AND_CARRY_ON]) {
		assert strange([pda], seeded(pdaSeed), op).result == 0;
		assert refusedAs(strange([pda], seeded(otherSeed), op), "PrivilegeEscalation");
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

test "a log line is kept whole when it is UTF-8, a zero byte included, and aborts when it is not" {
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

function rentOf(space: uint64): uint64 { return (space + 128) * 3480 * 2; }

const RENT_OF_8: uint64 = 946560;
const TOO_LARGE: uint64 = 10485761;

function createOf(amount: uint64, space: uint64, owner: Pubkey, tag: uint8): uint8[] {
	const data: uint8[] = [tag, 0, 0, 0];
	pushU64(data, amount);
	pushU64(data, space);
	for (const byte of owner.bytes) { data.push(byte); }
	return data;
}

function assignOf(owner: Pubkey): uint8[] {
	const data: uint8[] = [1, 0, 0, 0];
	for (const byte of owner.bytes) { data.push(byte); }
	return data;
}

function allocateOf(space: uint64): uint8[] {
	const data: uint8[] = [8, 0, 0, 0];
	pushU64(data, space);
	return data;
}

function laden(seed: uint8, fill: uint8 = 0): HostAccount {
	return { ...wallet(seed), data: [fill, fill, fill, fill, fill, fill, fill, fill] };
}

function blank(seed: uint8): HostAccount { return { ...wallet(seed), lamports: 0 }; }

function programOwned(seed: uint8[], data: uint8[] = [], lamports: uint64 = SOL): Passed {
	return flagged(holding(derived(seed), programKey(), lamports, data), true, true);
}

function unsignedBy(account: HostAccount): Passed { return flagged(account, true, false); }

function readOnly(account: HostAccount): Passed { return flagged(account, false, account.signer); }

function system(passed: Passed[], sent: uint8[], signing: Signing = unsigned()): Outcome {
	return forwarded(SYSTEM_PROGRAM_ID, passed, sent, signing);
}

function passes(outcome: Outcome): boolean { return outcome.result == 0 && outcome.fault == ""; }

function answers(outcome: Outcome, error: ProgramError): boolean {
	return outcome.result == error.code && outcome.fault == "";
}

function inUse(outcome: Outcome): boolean { return answers(outcome, ProgramError.custom(0)); }

function tooFewLamports(outcome: Outcome): boolean {
	return answers(outcome, ProgramError.custom(1));
}

function unsignedFor(outcome: Outcome): boolean {
	return answers(outcome, ProgramError.missingRequiredSignature());
}

function short(outcome: Outcome): boolean {
	return answers(outcome, ProgramError.invalidInstructionData());
}

test "the simulated System Transfer answers what the System program answers" {
	const seed = seedWhere(false, 0);
	const signed = seeded(seed);
	const to = held(wallet(2));
	const moved = system([held(wallet(1)), to], transferOf(5));
	assert passes(moved);
	assert moved.accounts[1].lamports == SOL - 5 && moved.accounts[2].lamports == SOL + 5;
	const trailing = transferOf(5);
	trailing.push(0);
	assert passes(system([held(wallet(1)), to], trailing));
	const itself = system([held(wallet(1)), held(wallet(1))], transferOf(5));
	assert passes(itself) && itself.accounts[1].lamports == SOL;
	assert tooFewLamports(system([held(wallet(1)), held(wallet(1))], transferOf(2 * SOL)));
	assert short(system([held(wallet(1)), to], [2, 0, 0, 0, 5, 0, 0, 0]));
	assert short(system([held(wallet(1))], [2, 0, 0, 0, 5, 0, 0, 0]));
	assert refusedAs(system([held(wallet(1))], transferOf(5)), "MissingAccount");
	assert unsignedFor(system([unsignedBy(wallet(1)), to], transferOf(5)));
	assert unsignedFor(system([unsignedBy(laden(1)), to], transferOf(5)));
	for (const amount of [5, 0]) {
		const refused = system([held(laden(1)), to], transferOf(amount as uint64));
		assert answers(refused, ProgramError.invalidArgument());
	}
	const ladenPda = system([programOwned(seed, zeros(8)), to], transferOf(5), signed);
	assert answers(ladenPda, ProgramError.invalidArgument());
	assert tooFewLamports(system([held(wallet(1)), to], transferOf(2 * SOL)));
	assert tooFewLamports(system([programOwned(seed), to], transferOf(2 * SOL), signed));
	assert tooFewLamports(system([readOnly(wallet(1)), to], transferOf(2 * SOL)));
	const spent = system([programOwned(seed), to], transferOf(5), signed);
	assert refusedAs(spent, "ExternalAccountLamportSpend");
	assert spent.accounts[1].lamports == SOL && spent.accounts[2].lamports == SOL;
	const pdaReadOnly = flagged(programOwned(seed).account, false, true);
	const spentReadOnly = system([pdaReadOnly, to], transferOf(5), signed);
	assert refusedAs(spentReadOnly, "ExternalAccountLamportSpend");
	assert passes(system([programOwned(seed), to], transferOf(0), signed));
	for (const amount of [5, 0]) {
		const sent = transferOf(amount as uint64);
		assert refusedAs(system([readOnly(wallet(1)), to], sent), "ReadonlyLamportChange");
		const kept = system([held(wallet(1)), readOnly(wallet(2))], sent);
		assert refusedAs(kept, "ReadonlyLamportChange");
		assert kept.accounts[1].lamports == SOL && kept.accounts[2].lamports == SOL;
	}
	const brimming = holding(keyOf(3), SYSTEM_PROGRAM_ID, 0xfffffffffffffff0);
	for (const target of [held(brimming), readOnly(brimming)]) {
		const overflowed = system([held(wallet(1)), target], transferOf(100));
		assert answers(overflowed, ProgramError.arithmeticOverflow());
		assert overflowed.accounts[1].lamports == SOL;
	}
}

test "the simulated System account creation answers what the System program answers" {
	const seed = seedWhere(false, 0);
	const signed = seeded(seed);
	for (const prefunds of [false, true]) {
		const tag: uint8 = prefunds ? 13 : 0;
		const sized = createOf(RENT_OF_8, 8, programKey(), tag);
		const creates = (from: Passed, at: Passed, sent: uint8[], signing: Signing): Outcome => {
			return system(prefunds ? [at, from] : [from, at], sent, signing);
		};
		const plain = (payer: Passed, target: Passed, sent: uint8[]): Outcome => {
			return creates(payer, target, sent, unsigned());
		};
		const payer = held(wallet(1));
		const target = held(blank(2));
		const made = plain(payer, target, sized);
		const account = made.accounts[prefunds ? 1 : 2];
		assert passes(made) && account.owner.equals(programKey()) && account.data.length == 8;
		assert account.lamports == RENT_OF_8;
		assert made.accounts[prefunds ? 2 : 1].lamports == SOL - RENT_OF_8;
		assert passes(plain(payer, target, createOf(0, 0, programKey(), tag)));
		assert passes(plain(payer, target, createOf(rentOf(10240), 10240, programKey(), tag)));
		const cut: uint8[] = [];
		for (let index = 0; index < 51; index++) { cut.push(sized[index]); }
		assert short(plain(payer, target, cut));
		assert refusedAs(system([target], sized), "MissingAccount");
		assert refusedAs(system([held(laden(2))], sized), "MissingAccount");
		for (const alone of [blank(2), wallet(2)]) {
			const outcome = system([held(alone)], createOf(0, 8, programKey(), tag));
			assert prefunds ? passes(outcome) : refusedAs(outcome, "MissingAccount");
		}

		const funded = plain(payer, held(wallet(2)), sized);
		assert prefunds ? passes(funded) : inUse(funded);
		assert funded.accounts[prefunds ? 1 : 2].lamports == (prefunds ? SOL + RENT_OF_8 : SOL);
		const unsignedFunded = plain(payer, unsignedBy(wallet(2)), sized);
		assert prefunds ? unsignedFor(unsignedFunded) : inUse(unsignedFunded);
		assert unsignedFor(plain(payer, unsignedBy(blank(2)), sized));
		assert inUse(plain(payer, held(laden(2)), sized));
		const unsignedLaden = plain(payer, unsignedBy(laden(2)), sized);
		assert prefunds ? unsignedFor(unsignedLaden) : inUse(unsignedLaden);
		assert inUse(creates(payer, programOwned(seed), sized, signed));
		assert inUse(creates(payer, programOwned(seed, [], 0), sized, signed));
		assert inUse(creates(payer, programOwned(seed, zeros(8), 0), sized, signed));
		assert inUse(plain(held(laden(1)), held(laden(2)), sized));
		const tooLarge = createOf(RENT_OF_8, TOO_LARGE, programKey(), tag);
		assert inUse(plain(payer, held(laden(2)), tooLarge));
		assert answers(plain(payer, target, tooLarge), ProgramError.custom(3));
		assert answers(plain(held(laden(1)), target, tooLarge), ProgramError.custom(3));
		assert refusedAs(plain(payer, readOnly(blank(2)), sized), "ReadonlyDataModified");
		for (const owner of [programKey(), SYSTEM_PROGRAM_ID]) {
			const empty = createOf(RENT_OF_8, 0, owner, tag);
			assert refusedAs(plain(payer, readOnly(blank(2)), empty), "ReadonlyDataModified");
		}

		const free = createOf(0, 8, programKey(), tag);
		assert unsignedFor(plain(unsignedBy(wallet(1)), target, sized));
		assert unsignedFor(plain(unsignedBy(laden(1)), target, sized));
		const freeUnsigned = plain(unsignedBy(wallet(1)), target, free);
		assert prefunds ? passes(freeUnsigned) : unsignedFor(freeUnsigned);
		assert answers(plain(held(laden(1)), target, sized), ProgramError.invalidArgument());
		const freeLaden = plain(held(laden(1)), target, free);
		assert prefunds
			? passes(freeLaden)
			: answers(freeLaden, ProgramError.invalidArgument());
		assert tooFewLamports(plain(payer, target, createOf(2 * SOL, 8, programKey(), tag)));
		assert tooFewLamports(plain(payer, target, createOf(2 * SOL, 10241, programKey(), tag)));
		const foreignPayer = creates(programOwned(seed), target, sized, signed);
		assert refusedAs(foreignPayer, "ExternalAccountLamportSpend");
		assert foreignPayer.accounts[prefunds ? 1 : 2].data.length == 0;
		assert refusedAs(plain(readOnly(wallet(1)), target, sized), "ReadonlyLamportChange");
		const grown = plain(payer, target, createOf(RENT_OF_8, 10241, programKey(), tag));
		assert answers(grown, ProgramError.invalidRealloc());
		assert grown.accounts[1].lamports + grown.accounts[2].lamports == SOL;

		const same = system([payer, payer], sized);
		assert prefunds ? answers(same, ProgramError.invalidArgument()) : inUse(same);
		const sameEmpty = system([payer, payer], createOf(5, 0, programKey(), tag));
		assert prefunds ? refusedAs(sameEmpty, "ExternalAccountLamportSpend") : inUse(sameEmpty);
		const sameSystem = system([payer, payer], createOf(5, 0, SYSTEM_PROGRAM_ID, tag));
		assert prefunds ? passes(sameSystem) : inUse(sameSystem);
	}
}

test "the simulated System Allocate answers what the System program answers" {
	const seed = seedWhere(false, 0);
	const sized = system([held(wallet(1))], allocateOf(8));
	assert passes(sized) && sized.accounts[1].data.length == 8;
	assert sized.accounts[1].owner.equals(SYSTEM_PROGRAM_ID);
	assert passes(system([held(wallet(1))], allocateOf(0)));
	assert passes(system([held(wallet(1))], allocateOf(10240)));
	assert passes(system([held(blank(1))], allocateOf(8)));
	assert short(system([held(wallet(1))], [8, 0, 0, 0, 8, 0, 0, 0]));
	assert refusedAs(system([], allocateOf(8)), "MissingAccount");
	assert unsignedFor(system([unsignedBy(wallet(1))], allocateOf(8)));
	assert unsignedFor(system([unsignedBy(laden(1))], allocateOf(8)));
	assert inUse(system([held(laden(1))], allocateOf(16)));
	assert inUse(system([programOwned(seed)], allocateOf(8), seeded(seed)));
	assert inUse(system([held(laden(1))], allocateOf(TOO_LARGE)));
	assert answers(system([held(wallet(1))], allocateOf(TOO_LARGE)), ProgramError.custom(3));
	for (const space of [8, 0]) {
		const refused = system([readOnly(wallet(1))], allocateOf(space as uint64));
		assert refusedAs(refused, "ReadonlyDataModified");
	}
	assert answers(system([held(wallet(1))], allocateOf(10241)), ProgramError.invalidRealloc());
}

test "the simulated System Assign answers what the System program answers" {
	const seed = seedWhere(false, 0);
	const given = system([held(wallet(1))], assignOf(programKey()));
	assert passes(given) && given.accounts[1].owner.equals(programKey());
	assert passes(system([held(laden(1))], assignOf(programKey())));
	assert passes(system([unsignedBy(wallet(1))], assignOf(SYSTEM_PROGRAM_ID)));
	assert passes(system([readOnly(wallet(1))], assignOf(SYSTEM_PROGRAM_ID)));
	const cut = assignOf(programKey());
	cut.pop();
	assert short(system([held(wallet(1))], cut));
	assert short(system([], cut));
	assert refusedAs(system([], assignOf(programKey())), "MissingAccount");
	assert unsignedFor(system([unsignedBy(wallet(1))], assignOf(programKey())));
	assert unsignedFor(system([unsignedBy(programOwned(seed).account)], assignOf(keyOf(8))));
	const foreign = system([programOwned(seed)], assignOf(keyOf(8)), seeded(seed));
	assert refusedAs(foreign, "ModifiedProgramId");
	assert foreign.accounts[1].owner.equals(programKey());
	assert refusedAs(system([held(laden(1, 7))], assignOf(programKey())), "ModifiedProgramId");
	assert refusedAs(system([readOnly(wallet(1))], assignOf(programKey())), "ModifiedProgramId");
}

const AFTER: uint8 = 5;
const WRITABLE: uint8 = 1;
const SIGNER: uint8 = 2;

function executable(key: Pubkey): HostAccount {
	return { ...holding(key, keyOf(0), 1), writable: false, executable: true };
}

function called(callee: uint8, metas: uint8[][], instruction: uint8[], step: uint8 = CALL): uint8[] {
	const bytes: uint8[] = [step, callee, metas.length as uint8];
	for (const meta of metas) {
		bytes.push(meta[0]);
		bytes.push(meta[1]);
	}
	bytes.push(instruction.length as uint8);
	for (const byte of instruction) { bytes.push(byte); }
	return bytes;
}

function stepped(steps: uint8[][], accounts: HostAccount[]): Outcome {
	const data: uint8[] = [STEPS];
	for (const step of steps) {
		for (const byte of step) { data.push(byte); }
	}
	return sent(data, accounts);
}

test "a call that fails ends the run with the callee's error, whether the program returns it or carries on" {
	for (const step of [CALL, CALL_AND_CARRY_ON]) {
		const after = (metas: uint8[][], instruction: uint8[]): Outcome => {
			const steps = [called(0, metas, instruction, step), [LOG, AFTER], called(0, metas, transferOf(5))];
			return stepped(steps, [executable(SYSTEM_PROGRAM_ID), wallet(1), wallet(2)]);
		};
		const signed: uint8[][] = [[1, WRITABLE + SIGNER], [2, WRITABLE]];
		const unsigned: uint8[][] = [[1, WRITABLE], [2, WRITABLE]];
		assert tooFewLamports(after(signed, transferOf(2 * SOL)));
		assert linesStarting("Program log: ") == 0 && invocations().length == 1;
		assert unsignedFor(after(unsigned, transferOf(5)));
		assert linesStarting("Program log: ") == 0 && invocations().length == 1;
		assert passes(after(signed, transferOf(5)));
		assert linesStarting("Program log: ") == 1 && invocations().length == 2;
	}
}

function added(index: uint8, amount: uint64): uint8[] {
	const step: uint8[] = [ADD, index];
	pushU64(step, amount);
	return step;
}

function subtracted(index: uint8, amount: uint64): uint8[] {
	const step: uint8[] = [SUBTRACT, index];
	pushU64(step, amount);
	return step;
}

function resized(index: uint8, length: uint8): uint8[] { return [RESIZE, index, length, 0]; }

function owned(seed: uint8, fill: uint8 = 0, lamports: uint64 = SOL): HostAccount {
	return holding(keyOf(seed), programKey(), lamports, [fill, fill, fill, fill, fill, fill, fill, fill]);
}

test "a run that fails leaves every account as it was before the run" {
	const fails: uint8[] = [FAIL, 7];
	const changes: uint8[][] = [subtracted(2, 5), added(3, 5), [WRITE, 2, 0, 9], resized(2, 16)];
	const create = called(0, [[1, WRITABLE + SIGNER], [4, WRITABLE + SIGNER]], createOf(RENT_OF_8, 8, programKey(), 0));
	const after = (steps: uint8[][]): Outcome => {
		return stepped(steps, [executable(SYSTEM_PROGRAM_ID), wallet(1), owned(2, 1), wallet(3), blank(4)]);
	};
	const untouched = (outcome: Outcome): boolean => {
		const own = outcome.accounts[2];
		const made = outcome.accounts[4];
		return own.lamports == SOL && own.data.length == 8 && own.data[0] == 1 && own.owner.equals(programKey())
			&& outcome.accounts[1].lamports == SOL && outcome.accounts[3].lamports == SOL
			&& made.lamports == 0 && made.data.length == 0 && made.owner.equals(SYSTEM_PROGRAM_ID);
	};
	const failed = after([changes[0], changes[1], changes[2], changes[3], fails]);
	assert answers(failed, ProgramError.custom(7)) && untouched(failed);
	const created = after([create, fails]);
	assert answers(created, ProgramError.custom(7)) && untouched(created);
	const closed = after([subtracted(2, SOL), added(3, SOL), resized(2, 0), [ASSIGN, 2, 0], fails]);
	assert answers(closed, ProgramError.custom(7)) && untouched(closed);
	const above = called(0, [[1, WRITABLE + SIGNER], [3, WRITABLE], [2, WRITABLE]], transferOf(2 * SOL));
	const refused = after([changes[0], changes[1], changes[2], changes[3], create, above]);
	assert tooFewLamports(refused) && untouched(refused);
	const faulted = after([changes[0], changes[1], changes[2], changes[3], create, called(0, [], [4, 0, 0, 0])]);
	assert notSimulated(faulted, "System program instruction 4 is not simulated") && untouched(faulted);
	const pays = called(0, [[1, WRITABLE + SIGNER], [3, WRITABLE]], transferOf(5));
	const unbalanced = after([pays, added(2, 1)]);
	assert refusedAs(unbalanced, "UnbalancedInstruction") && untouched(unbalanced);
	const kept = after([changes[0], changes[1], changes[2], changes[3], create]);
	assert passes(kept) && kept.accounts[2].lamports == SOL - 5 && kept.accounts[3].lamports == SOL + 5;
	assert kept.accounts[2].data.length == 16 && kept.accounts[2].data[0] == 9;
	assert kept.accounts[4].lamports == RENT_OF_8 && kept.accounts[4].owner.equals(programKey());
}

function belowRent(outcome: Outcome, index: int32): boolean {
	return refusedAs(outcome, "InsufficientFundsForRent") && outcome.fault.indexOf(` account ${index} `) > 0;
}

function gone(account: HostAccount): boolean {
	return account.lamports == 0 && account.data.length == 0 && account.owner.equals(SYSTEM_PROGRAM_ID);
}

function moved(from: uint8, to: uint8, amount: uint64): uint8[][] {
	return [subtracted(from, amount), added(to, amount)];
}

test "the rent the simulator asks is the rent minimumBalance reads on the host" {
	assert rentOf(8) == RENT_OF_8;
	for (const space of [0, 8, 165, 10240, 10485760]) {
		const floor = minimumBalance(space as uint64);
		assert floor.ok && rentOf(space as uint64) == floor.value;
	}
}

test "an account the System program creates or funds below its rent fails the run, as the transaction fails" {
	const system = executable(SYSTEM_PROGRAM_ID);
	const signs: uint8 = WRITABLE + SIGNER;
	for (const tag of [0, 13]) {
		const metas: uint8[][] = tag == 0 ? [[1, signs], [2, signs]] : [[2, signs], [1, signs]];
		for (const space of [0, 8]) {
			const creates = (amount: uint64): Outcome => {
				const sent = createOf(amount, space as uint64, programKey(), tag as uint8);
				return stepped([called(0, metas, sent)], [system, wallet(1), blank(2)]);
			};
			const poor = creates(rentOf(space as uint64) - 1);
			assert belowRent(poor, 2) && gone(poor.accounts[2]) && poor.accounts[1].lamports == SOL;
			const exact = creates(rentOf(space as uint64));
			assert passes(exact) && exact.accounts[2].data.length == space;
		}
	}
	const sends = (amount: uint64, from: HostAccount, to: HostAccount): Outcome => {
		return stepped([called(0, [[1, signs], [2, WRITABLE]], transferOf(amount))], [system, from, to]);
	};
	assert belowRent(sends(1, wallet(1), blank(2)), 2);
	assert belowRent(sends(rentOf(0) - 1, wallet(1), blank(2)), 2);
	assert passes(sends(rentOf(0), wallet(1), blank(2)));
	const leaving: HostAccount = { ...wallet(1), lamports: rentOf(0) + 10 };
	assert belowRent(sends(11, leaving, wallet(2)), 1);
	assert passes(sends(10, leaving, wallet(2)));
	const emptied = sends(rentOf(0) + 10, leaving, wallet(2));
	assert passes(emptied) && gone(emptied.accounts[1]);
	const thin: HostAccount = { ...wallet(2), signer: false, lamports: 1000 };
	assert passes(stepped([], [system, wallet(1), thin]));
	assert belowRent(sends(1, wallet(1), thin), 2);
	const incinerator = Pubkey.parse("1nc1nerator11111111111111111111111111111111");
	assert incinerator.ok;
	if (incinerator.ok) { assert passes(sends(1, wallet(1), holding(incinerator.value, SYSTEM_PROGRAM_ID, 0))); }
}

test "lamports the program moves or bytes it adds that leave an account below its rent fail the run" {
	const system = executable(SYSTEM_PROGRAM_ID);
	const exact = (steps: uint8[][]): Outcome => stepped(steps, [system, owned(1, 0, RENT_OF_8), wallet(2)]);
	assert belowRent(exact(moved(1, 2, 1)), 1);
	assert belowRent(exact([resized(1, 9)]), 1);
	assert passes(exact([resized(1, 4)]));
	const rich = (steps: uint8[][]): Outcome => stepped(steps, [system, owned(1, 7), wallet(2)]);
	assert passes(rich(moved(1, 2, SOL - RENT_OF_8)));
	const emptied = rich(moved(1, 2, SOL));
	assert passes(emptied) && gone(emptied.accounts[1]) && emptied.accounts[2].lamports == 2 * SOL;
	const below = (steps: uint8[][]): Outcome => {
		return stepped(steps, [system, owned(1, 0, 1000), wallet(2), owned(3)]);
	};
	assert passes(below([[WRITE, 1, 0, 9]]));
	assert passes(below(moved(1, 2, 1)));
	assert belowRent(below(moved(3, 1, 1)), 1);
	assert passes(below(moved(3, 1, RENT_OF_8 - 1000)));
	assert belowRent(below([resized(1, 9)]), 1);
	assert belowRent(below([resized(1, 4)]), 1);
	assert belowRent(below([subtracted(1, 1), added(2, 1), resized(1, 4)]), 1);
	const readOnly: HostAccount = { ...owned(1, 0, 1000), writable: false };
	assert passes(stepped([], [system, readOnly]));
}

const CALLEE: uint8 = 0;
const OWN: uint8 = 1;
const WALLET: uint8 = 2;
const OWN_READ_ONLY: uint8 = 3;
const FOREIGN: uint8 = 4;
const FOREIGN_READ_ONLY: uint8 = 5;
const OWN_SET: uint8 = 6;
const PROGRAM: uint8 = 7;

function does(steps: uint8[][]): Outcome {
	const foreign = holding(keyOf(4), keyOf(8), SOL, zeros(8));
	const accounts: HostAccount[] = [
		executable(keyOf(8)),
		owned(1),
		{ ...wallet(2), signer: false },
		{ ...owned(3), writable: false },
		foreign,
		{ ...foreign, key: keyOf(5), writable: false },
		owned(6, 7),
		executable(programKey()),
	];
	return stepped(steps, accounts);
}

function refuses(steps: uint8[][], runtimeError: string): boolean {
	return refusedAs(does(steps), runtimeError) && linesStarting("Program log: ") == 0;
}

function wrote(index: uint8, value: uint8 = 9): uint8[] { return [WRITE, index, 0, value]; }

function gave(index: uint8, to: uint8): uint8[] { return [ASSIGN, index, to]; }

function receiving(metas: uint8[][], step: uint8 = CALL): uint8[] { return called(CALLEE, metas, [0], step); }

test "lamports the program moves are refused at the end of its instruction where the runtime refuses them" {
	assert refuses([added(OWN, 1)], "UnbalancedInstruction");
	assert refuses([subtracted(OWN, 1)], "UnbalancedInstruction");
	const paid = does(moved(OWN, WALLET, 5));
	assert passes(paid) && paid.accounts[1].lamports == SOL - 5 && paid.accounts[2].lamports == SOL + 5;
	assert passes(does(moved(OWN, FOREIGN, 5)));
	assert refuses(moved(WALLET, OWN, 5), "ExternalAccountLamportSpend");
	assert refuses(moved(OWN, FOREIGN_READ_ONLY, 5), "ReadonlyLamportChange");
	assert refuses(moved(OWN_READ_ONLY, OWN, 5), "ReadonlyLamportChange");
	assert refuses(moved(FOREIGN_READ_ONLY, OWN, 5), "ExternalAccountLamportSpend");
	assert refuses(moved(OWN, CALLEE, 5), "ReadonlyLamportChange");
}

test "data and owners the program writes are refused at the end of its instruction where the runtime refuses them" {
	assert passes(does([wrote(OWN)]));
	assert refuses([wrote(FOREIGN)], "ExternalAccountDataModified");
	assert passes(does([wrote(FOREIGN, 0)]));
	assert refuses([wrote(OWN_READ_ONLY)], "ReadonlyDataModified");
	assert refuses([wrote(FOREIGN_READ_ONLY)], "ReadonlyDataModified");
	const given = does([gave(OWN, CALLEE)]);
	assert passes(given) && given.accounts[1].owner.equals(keyOf(8));
	assert passes(does([gave(OWN_SET, PROGRAM)]));
	assert refuses([gave(OWN_SET, CALLEE)], "ModifiedProgramId");
	assert refuses([wrote(OWN), gave(OWN, CALLEE)], "ModifiedProgramId");
	assert refuses([gave(OWN_READ_ONLY, CALLEE)], "ModifiedProgramId");
	assert refuses([gave(FOREIGN, PROGRAM)], "ModifiedProgramId");
	assert refuses([gave(WALLET, PROGRAM)], "ModifiedProgramId");
	assert passes(does([resized(OWN, 16)]));
	assert passes(does([resized(OWN, 0)]));
	assert refuses([resized(FOREIGN, 16)], "ExternalAccountDataModified");
	assert refuses([resized(FOREIGN, 4)], "ExternalAccountDataModified");
	assert refuses([resized(WALLET, 8)], "ExternalAccountDataModified");
	assert refuses([resized(OWN_READ_ONLY, 16)], "ReadonlyDataModified");
	assert refuses([wrote(FOREIGN), subtracted(FOREIGN, 5), added(OWN, 5)], "ExternalAccountLamportSpend");
	assert refuses([gave(FOREIGN, PROGRAM), wrote(FOREIGN)], "ExternalAccountDataModified");
	assert refuses([wrote(FOREIGN), resized(FOREIGN, 16)], "ExternalAccountDataModified");
	assert refuses([added(OWN, 1), wrote(FOREIGN)], "ExternalAccountDataModified");
}

test "what the program wrote to the accounts a call receives is judged at the call, and cannot be carried past it" {
	const out = subtracted(OWN, 5);
	const into = added(WALLET, 5);
	const after: uint8[] = [LOG, AFTER];
	const carried = (metas: uint8[][]): uint8[] => receiving(metas, CALL_AND_CARRY_ON);
	assert passes(does([out, into, receiving([[OWN, WRITABLE], [WALLET, WRITABLE]])]));
	assert passes(does([out, into, receiving([[OWN, 0], [WALLET, 0]])]));
	assert passes(does([out, into, receiving([])]));
	assert refuses([out, into, carried([[OWN, WRITABLE]]), after], "UnbalancedInstruction");
	assert invocations().length == 0;
	assert refuses([out, into, carried([[WALLET, 0]]), after], "UnbalancedInstruction");
	assert passes(does([added(OWN, 1), receiving([]), subtracted(OWN, 1)]));
	assert refuses([added(OWN, 1), carried([[OWN, WRITABLE]]), subtracted(OWN, 1), after], "UnbalancedInstruction");
	const spent = [subtracted(WALLET, 5), added(OWN, 5), carried([[WALLET, WRITABLE]]), after];
	assert refuses(spent, "ExternalAccountLamportSpend");
	const credited = [out, added(FOREIGN_READ_ONLY, 5), carried([[OWN, WRITABLE], [FOREIGN_READ_ONLY, 0]]), after];
	assert refuses(credited, "ReadonlyLamportChange");
	assert passes(does([subtracted(WALLET, 5), receiving([]), added(WALLET, 5)]));
	assert refuses([wrote(FOREIGN), carried([[FOREIGN, 0]]), after], "ExternalAccountDataModified");
	assert invocations().length == 0;
	assert passes(does([wrote(FOREIGN), receiving([[OWN, WRITABLE]]), wrote(FOREIGN, 0)]));
	assert refuses([wrote(OWN_READ_ONLY), carried([[OWN_READ_ONLY, 0]]), after], "ReadonlyDataModified");
	assert refuses([gave(FOREIGN, PROGRAM), carried([[FOREIGN, 0]]), after], "ModifiedProgramId");
	assert refuses([resized(FOREIGN, 16), carried([[FOREIGN, 0]]), after], "ExternalAccountDataModified");
	assert refuses([gave(OWN, CALLEE), receiving([[OWN, WRITABLE]]), wrote(OWN)], "ExternalAccountDataModified");
	assert refuses([gave(OWN, CALLEE), receiving([]), wrote(OWN)], "ModifiedProgramId");
}
