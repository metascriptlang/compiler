// GUARD-OS solana
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'writablePda'
// GUARD-CHECK-FAIL Module 'std/solana/typed' has no export 'writablePda'
// GUARD-CHECK-FAIL Module 'std/solana/typed' has no export 'writablePdaProofFailure'
// GUARD-CHECK-FAIL Module 'std/solana/typed' has no export 'writablePdaProof'
// A WritablePda comes only from accounts<T>() with @seeds, which stores the bump the declared seeds
// found. No exported function builds one from an index alone, from the barrel or from std/solana/typed.
// RED MEANS: an author calls writablePda(index) and hands createPda<T>() a proof whose bump is 0, so
// the account is created at the bump-0 address (not the canonical one) and pda() later refuses it with 2006.
import { writablePda } from "std/solana";
import { writablePda as direct, writablePdaProof, writablePdaProofFailure } from "std/solana/typed";

function doors(): void {
	const a = writablePda(1);
	const b = direct(1);
	const c = writablePdaProof(1, 0);
	const d = writablePdaProofFailure(1, 0);
}
