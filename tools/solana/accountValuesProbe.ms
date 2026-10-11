import { Discriminator, Owned, ProgramError, accountDiscriminator, accounts, failWith, instruction, logU64 } from "std/solana";
export enum ReadOp { Read }
export enum Species { Cat, Dog, Fox }
export struct Flags { alive: boolean; kind: Species; }
export struct Pet { flags: Flags; kinds: Species[64]; }
export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Pet"); };
}
export struct ReadAccounts { pet: Owned<Pet>; }
function readAccount(): Result<uint64, ProgramError> {
	const x = try accounts<ReadAccounts>();
	const pet = x.pet.data();
	let sum: uint64 = pet.flags.alive ? 100 : 0;
	for (let i = 0; i < 64; i += 1) { sum += pet.kinds[i] as uint64; }
	logU64(sum);
	return Result.ok(0);
}
export function dispatch(): Result<uint64, ProgramError> {
	return match (try instruction<ReadOp>()) { ReadOp.Read => readAccount() };
}
export function entry(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
entry();
