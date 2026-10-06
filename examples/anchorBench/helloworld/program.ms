import {
	Discriminator,
	Program,
	ProgramError,
	System,
	Writable,
	WritableSigner,
	accountDiscriminator,
	accounts,
	createPda,
	failWith,
	instruction,
} from "std/solana";

export enum HelloOp {
	Init,
}

export struct Counter {
	value: uint64;
	bump: uint8;
	pad: uint8[7];
}

export function discriminator(this typeof Counter): Discriminator {
	return @comptime { return accountDiscriminator("Counter"); };
}

export struct InitAccounts {
	payer: WritableSigner;
	counter: Writable;
	systemProgram: Program<System>;
}

function init(): Result<uint64, ProgramError> {
	const x = try accounts<InitAccounts>();
	const made = try createPda<Counter>(x.payer, x.counter, ["counter"]);
	const counter = made.account.data();
	counter.value = 42;
	counter.bump = made.bump;
	return Result.ok(0);
}

export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<HelloOp>()) {
		HelloOp.Init => init(),
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

	function holder(key: Pubkey, owner: Pubkey, lamports: uint64): HostAccount {
		return { key: key, owner: owner, lamports: lamports, data: [], signer: false, writable: true, executable: false };
	}

	function initAccounts(program: Pubkey): HostAccount[] {
		let payer = Pubkey.zero();
		payer.bytes[0] = 1;
		const counter = findProgramAddressOf(program, ["counter"]);
		return [
			{ ...holder(payer, SYSTEM_PROGRAM_ID, 10000000000), signer: true },
			holder(counter.ok ? counter.value.key : Pubkey.zero(), SYSTEM_PROGRAM_ID, 0),
			{ ...holder(SYSTEM_PROGRAM_ID, Pubkey.zero(), 1), writable: false, executable: true },
		];
	}

	function initData(): uint8[] {
		const discriminator = instructionDiscriminator("Init");
		const bytes: uint8[] = [];
		for (let i = 0; i < 8; i++) { bytes.push(discriminator.bytes[i]); }
		return bytes;
	}

	test "init creates the counter at the address its literal seeds fold to under the declared id" {
		const accounts = initAccounts(declaredProgramId());
		assert run(declaredProgramId(), accounts, initData(), entry).result == 0;
		assert accounts[1].owner == declaredProgramId() && accounts[1].data[8] == 42;
	}

	test "a program deployed under another id refuses every instruction with Anchor's 4100" {
		let other = declaredProgramId();
		other.bytes[0] = other.bytes[0] ^ 1;
		const accounts = initAccounts(other);
		assert run(other, accounts, initData(), entry).result == ProgramError.declaredProgramIdMismatch().code;
		assert accounts[1].owner == SYSTEM_PROGRAM_ID;
	}

	test "the folded address refuses a counter account off it" {
		const accounts = initAccounts(declaredProgramId());
		accounts[1].key.bytes[31] = accounts[1].key.bytes[31] ^ 1;
		assert run(declaredProgramId(), accounts, initData(), entry).result == ProgramError.constraintSeeds().code;
	}
}
