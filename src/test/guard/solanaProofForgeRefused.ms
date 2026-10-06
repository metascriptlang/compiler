// GUARD-OS solana
// GUARD-CHECK-FAIL solanaProofForgeRefused.ms:33:
// GUARD-CHECK-FAIL solanaProofForgeRefused.ms:34:
// GUARD-CHECK-FAIL solanaProofForgeRefused.ms:35:
// GUARD-CHECK-FAIL solanaProofForgeRefused.ms:36:
// GUARD-CHECK-FAIL solanaProofForgeRefused.ms:37:
// GUARD-CHECK-FAIL solanaProofForgeRefused.ms:38:
// GUARD-CHECK-FAIL solanaProofForgeRefused.ms:39:
// GUARD-CHECK-FAIL 'account' is a private field of 'WritableSigner'
// GUARD-CHECK-FAIL cannot convert Owned<Pet> to Mutable<Pet>
// A proof comes only from its verifier: outside std/solana an account, a weaker proof or another
// proof's type converts to no proof, by `as` or by a literal, and the weakening calls and the
// readers still compile.
// RED MEANS: a program builds a Signer, a WritableSigner or a Mutable<T> its accounts never proved,
// so an unsigned or foreign account passes as signed or owned.
import { Account, Discriminator, Mutable, Owned, ProgramError, Signer, WritableSigner, accountDiscriminator, asAccount, failWith, owned, unchecked, writableSigner } from "std/solana";

export struct Pet {
	hearts: uint64;
}

export function discriminator(this typeof Pet): Discriminator {
	return @comptime { return accountDiscriminator("Pet"); };
}

function allowed(payer: WritableSigner, pet: Owned<Pet>): uint64 {
	const weaker: Signer = payer.asSigner();
	const raw: Account = pet.asAccount();
	return weaker.lamports() + raw.lamports() + pet.lamports();
}

function forged(raw: Account, signed: Signer, pet: Owned<Pet>): void {
	const a = raw as Signer;
	const b: WritableSigner = { account: raw };
	const c = signed as WritableSigner;
	const d = raw as Owned<Pet>;
	const e: Mutable<Pet> = { account: raw };
	const f = pet as Mutable<Pet>;
	const g = pet.asAccount() as Mutable<Pet>;
}

function main(): void {
	const payer = writableSigner(0);
	const pet = owned<Pet>(1);
	const raw = unchecked(2);
	if (!payer.ok || !pet.ok || !raw.ok) { failWith(ProgramError.invalidArgument()); return; }
	allowed(payer.value, pet.value);
	forged(raw.value, payer.value.asSigner(), pet.value);
}

main();
