// GUARD-OS solana
// GUARD-CHECK-FAIL signerProof
// GUARD-CHECK-FAIL ownedProof
// GUARD-CHECK-FAIL 'signer' may be read before it is assigned: type 'Signer' has a private field
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'closedProgramAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'resizedProgramAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createdAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createdPdaAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createAccountAllowPrefund'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'seedsGivenProvenFailure'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'createPdaAt'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'slottedSeeds'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'keysEqual'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'foundSigner'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'canonicalBumpProven'
import { Signer, signerProof } from "std/solana/typed"; // GUARD-REFUSED
import { Owned, ownedProof } from "std/solana"; // GUARD-REFUSED
import { closedProgramAccount, resizedProgramAccount, createdAccount, createdPdaAccount, createAccountAllowPrefund, seedsGivenProvenFailure, createPdaAt, slottedSeeds, keysEqual, foundSigner, canonicalBumpProven } from "std/solana"; // GUARD-REFUSED

struct PrivateFactoryPet { value: uint64; }

function bypass(): void {
	let signer: Signer;
	signerProof(0, signer); // GUARD-REFUSED
	let pet: Owned<PrivateFactoryPet>;
	ownedProof<PrivateFactoryPet>(1, pet); // GUARD-REFUSED
}

bypass();
