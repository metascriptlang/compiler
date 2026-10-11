// GUARD-CHECK-FAIL SOLANA_ACCOUNT_FIELD
import { Discriminator, Owned, ProgramError, accountDiscriminator, owned } from "std/solana";

export struct UnsafeAccount { pointer: Ptr<uint8>; }
export function discriminator(this typeof UnsafeAccount): Discriminator {
	return @comptime { return accountDiscriminator("UnsafeAccount"); };
}
export function unsafeProof(index: int32): Result<Owned<UnsafeAccount>, ProgramError> {
	return owned<UnsafeAccount>(index);
}
