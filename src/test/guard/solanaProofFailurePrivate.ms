// GUARD-OS solana
// GUARD-CHECK-FAIL signerProofFailure
// GUARD-CHECK-FAIL ownedProofFailure
// GUARD-CHECK-FAIL 'signer' may be read before it is assigned: type 'Signer' has a private field
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'closedProgramAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'resizedProgramAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createdAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createdPdaAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createAccountAllowPrefund'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'mutableFailure'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'seedsGivenProvenFailure'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createPdaAt'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'slottedSeeds'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'keysEqual'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'foundSigner'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'canonicalBumpProven'
import { Signer, signerProofFailure } from "std/solana/typed";
import { Owned, ownedProofFailure } from "std/solana";
import { closedProgramAccount, resizedProgramAccount, createdAccount, createdPdaAccount, createAccountAllowPrefund, mutableFailure, seedsGivenProvenFailure, createPdaAt, slottedSeeds, keysEqual, foundSigner, canonicalBumpProven } from "std/solana";

struct PrivateFactoryPet { value: uint64; }

function bypass(): void {
	let signer: Signer;
	signerProofFailure(0, signer);
	let pet: Owned<PrivateFactoryPet>;
	ownedProofFailure<PrivateFactoryPet>(1, pet);
}

bypass();
