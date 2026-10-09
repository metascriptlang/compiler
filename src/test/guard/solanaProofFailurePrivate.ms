// GUARD-OS solana
// GUARD-CHECK-FAIL signerProofFailure
// GUARD-CHECK-FAIL ownedProofFailure
import { Signer, signerProofFailure } from "std/solana/typed";
import { Owned, ownedProofFailure } from "std/solana";

struct PrivateFactoryPet { value: uint64; }

function bypass(): void {
	let signer: Signer;
	signerProofFailure(0, signer);
	let pet: Owned<PrivateFactoryPet>;
	ownedProofFailure<PrivateFactoryPet>(1, pet);
}

bypass();
