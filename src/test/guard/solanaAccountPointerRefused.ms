// GUARD-CHECK-FAIL SOLANA_ACCOUNT_FIELD
import { Discriminator, Owned, ProgramError, owned } from "std/solana";

export struct UnsafeAccount { pointer: Ptr<uint8>; }
export function discriminator(this typeof UnsafeAccount): Discriminator {
	return { bytes: [1, 2, 3, 4, 5, 6, 7, 8] };
}
export function unsafeProof(index: int32): Result<Owned<UnsafeAccount>, ProgramError> {
	return owned<UnsafeAccount>(index);
}
