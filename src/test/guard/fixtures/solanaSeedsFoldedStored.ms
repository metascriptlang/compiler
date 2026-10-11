import {
	Discriminator,
	Mutable,
	ProgramError,
	Signer,
	accountDiscriminator,
	accounts,
	bump,
	failWith,
	instruction,
	seeds,
} from "std/solana";

export enum CounterOp {
	Bump,
}

export struct Counter {
	value: uint64;
	bump: uint8;
	pad: uint8[7];
}

export function discriminator(this typeof Counter): Discriminator {
	return @comptime { return accountDiscriminator("Counter"); };
}

export struct BumpAccounts {
	admin: Signer;
	@seeds("counter", [7, 9]) @bump(counter.bump) counter: Mutable<Counter>;
}

function bumpCounter(): Result<uint64, ProgramError> {
	const x = try accounts<BumpAccounts>();
	x.counter.data().value += 1;
	return Result.ok(0);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<CounterOp>()) {
		CounterOp.Bump => bumpCounter(),
	};
}

export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}

when (!testBuild) {
	entry();
}

when (testBuild) {
	import { Pubkey, SYSTEM_PROGRAM_ID, declaredProgramId, findProgramAddressOf, instructionDiscriminator } from "std/solana";
	import { HostAccount, run } from "std/solana/host";
	import { sha256 } from "std/crypto/sha256";
	import { isEdwardsPoint } from "std/crypto/ed25519/point";

	function counterAt(key: Pubkey, owner: Pubkey, bump: uint8): HostAccount {
		const data: uint8[] = [];
		const tag = accountDiscriminator("Counter");
		for (let i = 0; i < 8; i++) { data.push(tag.bytes[i]); }
		for (let i = 0; i < 16; i++) { data.push(0); }
		data[16] = bump;
		return { key: key, owner: owner, lamports: 1000000000, data: data, signer: false, writable: true, executable: false };
	}

	function bumpAccounts(counter: HostAccount): HostAccount[] {
		let admin = Pubkey.zero();
		admin.bytes[0] = 1;
		return [
			{ key: admin, owner: SYSTEM_PROGRAM_ID, lamports: 1000000000, data: [], signer: true, writable: false, executable: false },
			counter,
		];
	}

	function bumpData(): uint8[] {
		const discriminator = instructionDiscriminator("Bump");
		const bytes: uint8[] = [];
		for (let i = 0; i < 8; i++) { bytes.push(discriminator.bytes[i]); }
		return bytes;
	}

	function canonical(program: Pubkey): Pubkey {
		const found = findProgramAddressOf(program, ["counter", [7, 9]]);
		return found.ok ? found.value.key : Pubkey.zero();
	}

	function canonicalBump(program: Pubkey): uint8 {
		const found = findProgramAddressOf(program, ["counter", [7, 9]]);
		return found.ok ? found.value.bump : 0;
	}

	function hashed(program: Pubkey, bump: uint8): Pubkey {
		let preimage: uint8[] = [99, 111, 117, 110, 116, 101, 114, 7, 9, bump];
		for (const byte of program.bytes) { preimage.push(byte); }
		for (const byte of "ProgramDerivedAddress".asBytes()) { preimage.push(byte); }
		return { bytes: sha256(preimage).bytes };
	}

	function lowerOffCurveBump(program: Pubkey): uint8 {
		for (let bump = (canonicalBump(program) as int32) - 1; bump >= 1; bump--) {
			if (!isEdwardsPoint(hashed(program, bump as uint8).bytes)) { return bump as uint8; }
		}
		return 0;
	}

	function result(program: Pubkey, counter: HostAccount): uint64 {
		return run(program, bumpAccounts(counter), bumpData(), entry).result;
	}

	test "the folded stored bump accepts the canonical address with the canonical bump" {
		const program = declaredProgramId();
		const accounts = bumpAccounts(counterAt(canonical(program), program, canonicalBump(program)));
		assert run(program, accounts, bumpData(), entry).result == 0;
		assert accounts[1].data[8] == 1;
	}

	test "the folded stored bump refuses a stored bump other than the canonical one at the canonical address" {
		const program = declaredProgramId();
		const code = ProgramError.constraintSeeds().code;
		assert result(program, counterAt(canonical(program), program, canonicalBump(program) - 1)) == code;
		assert result(program, counterAt(canonical(program), program, 0)) == code;
		assert result(program, counterAt(canonical(program), program, 255)) == (canonicalBump(program) == 255 ? 0 : code);
	}

	test "the folded stored bump refuses an address one bit off or the address of other literal seeds" {
		const program = declaredProgramId();
		const code = ProgramError.constraintSeeds().code;
		let off = canonical(program);
		off.bytes[0] = off.bytes[0] ^ 1;
		assert result(program, counterAt(off, program, canonicalBump(program))) == code;
		const other = findProgramAddressOf(program, ["counter", [7, 8]]);
		assert other.ok;
		assert result(program, counterAt(other.value.key, program, other.value.bump)) == code;
	}

	test "the folded stored bump refuses the off-curve address of a lower bump with its own stored bump" {
		const program = declaredProgramId();
		const lower = lowerOffCurveBump(program);
		assert lower != 0;
		assert result(program, counterAt(hashed(program, lower), program, lower)) == ProgramError.constraintSeeds().code;
	}

	test "the folded stored bump refuses an account of another owner before the seeds" {
		const program = declaredProgramId();
		assert result(program, counterAt(canonical(program), SYSTEM_PROGRAM_ID, canonicalBump(program))) ==
			ProgramError.accountOwnedByWrongProgram().code;
	}

	test "the program run at another id refuses the declared id's PDA and fails closed on its own PDA" {
		const declared = declaredProgramId();
		let foreign = Pubkey.zero();
		foreign.bytes[0] = 77;
		const own = findProgramAddressOf(foreign, ["counter", [7, 9]]);
		assert own.ok;
		assert result(foreign, counterAt(canonical(declared), declared, canonicalBump(declared))) ==
			ProgramError.accountOwnedByWrongProgram().code;
		assert result(foreign, counterAt(own.value.key, foreign, own.value.bump)) == ProgramError.constraintSeeds().code;
	}
}
