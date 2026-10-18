import { External, ExternalMutable, Delegated, Mutable, Owned, Program, delegated, external, externalMutable, mutable, owned, program } from "./typed";
import { Account, System } from "./core";
import { Discriminator, accountDiscriminator } from "./discriminator";
import { ProgramError } from "./error";
import { Pubkey } from "./pubkey";

export struct DirectPet { value: uint64; }
export function discriminator(this typeof DirectPet): Discriminator {
	return @comptime { return accountDiscriminator("DirectPet"); };
}

export struct DirectVerifier { unused: uint8; }
export function acceptsOwner(this typeof DirectVerifier, owner: Pubkey): boolean { return true; }
export function verify(this typeof DirectVerifier, index: int32): Result<Account, ProgramError> {
	return Result.err(ProgramError.custom(77));
}

export function directProgram(): Result<Program<System>, ProgramError> { return program<System>(1); }
export function directOwned(): Result<Owned<DirectPet>, ProgramError> { return owned<DirectPet>(0); }
export function directMutable(): Result<Mutable<DirectPet>, ProgramError> { return mutable<DirectPet>(0); }
export function directDelegated(): Result<Delegated<DirectPet>, ProgramError> { return delegated<DirectPet>(0); }
export function directExternal(): Result<External<DirectVerifier>, ProgramError> { return external<DirectVerifier>(0); }
export function directExternalMutable(): Result<ExternalMutable<DirectVerifier>, ProgramError> {
	return externalMutable<DirectVerifier>(0);
}
