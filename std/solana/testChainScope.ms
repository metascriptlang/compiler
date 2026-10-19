import { Signer as Auth, Owned, Program, accounts, owned, program } from "./typed";
import { System } from "./core";
import { Discriminator, accountDiscriminator } from "./discriminator";
import { ProgramError } from "./error";
import { Pubkey } from "./pubkey";

export struct ScopedChainAccounts { owner: Auth; }

export function scopedChainResult() {
	return accounts<ScopedChainAccounts>();
}

export struct ScopedProgramAccounts { owner: Auth; system: Program<System>; }
export function scopedProgramResult() { return accounts<ScopedProgramAccounts>(); }
export function scopedDirectProgram(): Result<Program<System>, ProgramError> { return program<System>(1); }

export struct ScopedPet { value: uint64; }
export function discriminator(this typeof ScopedPet): Discriminator {
	return @comptime { return accountDiscriminator("ScopedPet"); };
}
export function scopedOwnedResult(): Result<Owned<ScopedPet>, ProgramError> { return owned<ScopedPet>(0); }

type HiddenFourBytes = uint8[4];
struct HiddenByteArgs {
	prefix: boolean;
	bytes: HiddenFourBytes;
	tail: uint64;
}
export type ScopedByteArgs = HiddenByteArgs;

type HiddenNoKeys = Pubkey[0];
type HiddenOneKey = Pubkey[1];
type HiddenTwoKeys = Pubkey[2];
export struct ScopedKeyArgs {
	empty: HiddenNoKeys;
	one: HiddenOneKey;
	two: HiddenTwoKeys;
}
