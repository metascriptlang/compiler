// GUARD-OS solana
// GUARD-CHECK-FAIL 'Guarded' extends 'Gate<Signer>', whose fields accounts<T>() cannot read
// accounts<T>() verifies the fields a struct inherits ahead of its own, from each base's
// declaration. A base whose declaration it cannot read is refused.
// RED MEANS: accounts<T>() built a struct whose inherited Signer no verifier checked.
import { ProgramError, Signer, Writable, accounts, failWith } from "std/solana";

export struct Gate<T> { authority: T; }
export struct Guarded extends Gate<Signer> { target: Writable; }

function run(): Result<uint64, ProgramError> {
	const x = try accounts<Guarded>();
	return Result.ok(x.authority.lamports() + x.target.lamports());
}

function main(): void {
	const result = run();
	if (!result.ok) { failWith(result.error); }
}

main();
