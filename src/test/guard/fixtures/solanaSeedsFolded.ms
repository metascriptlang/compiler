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
	@seeds("counter", [7, 9]) @bump counter: Mutable<Counter>;
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

	function counterAt(key: Pubkey, program: Pubkey): HostAccount {
		const data: uint8[] = [];
		const tag = accountDiscriminator("Counter");
		for (let i = 0; i < 8; i++) { data.push(tag.bytes[i]); }
		for (let i = 0; i < 16; i++) { data.push(0); }
		return { key: key, owner: program, lamports: 1000000000, data: data, signer: false, writable: true, executable: false };
	}

	function bumpAccounts(counter: Pubkey, program: Pubkey): HostAccount[] {
		let admin = Pubkey.zero();
		admin.bytes[0] = 1;
		return [
			{ key: admin, owner: SYSTEM_PROGRAM_ID, lamports: 1000000000, data: [], signer: true, writable: false, executable: false },
			counterAt(counter, program),
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

	test "the folded seeds accept the canonical address of a string and a byte-list seed" {
		const program = declaredProgramId();
		const accounts = bumpAccounts(canonical(program), program);
		assert run(program, accounts, bumpData(), entry).result == 0;
		assert accounts[1].data[8] == 1;
	}

	test "the folded seeds refuse an account one bit off the canonical address with ConstraintSeeds" {
		const program = declaredProgramId();
		let off = canonical(program);
		off.bytes[31] = off.bytes[31] ^ 1;
		const accounts = bumpAccounts(off, program);
		assert run(program, accounts, bumpData(), entry).result == ProgramError.constraintSeeds().code;
		assert accounts[1].data[8] == 0;
	}

	test "the folded seeds refuse the address of other literal seeds" {
		const program = declaredProgramId();
		const other = findProgramAddressOf(program, ["counter", [7, 8]]);
		const accounts = bumpAccounts(other.ok ? other.value.key : Pubkey.zero(), program);
		assert run(program, accounts, bumpData(), entry).result == ProgramError.constraintSeeds().code;
	}
}
