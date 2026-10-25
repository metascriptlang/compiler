// GUARD-OS solana
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:38:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:42:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:46:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:47:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:48:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:50:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:51:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:53:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:54:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:55:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:56:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:57:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:58:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:59:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:61:
// GUARD-CHECK-FAIL solanaAccountForgeRefused.ms:62:
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'CpiAccount'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'CpiInstruction'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'accountAt'
// GUARD-CHECK-FAIL Module 'std/solana' has no export 'invokeCpi'
// GUARD-CHECK-FAIL 'address' is a private field of 'Account'
// GUARD-CHECK-FAIL type 'Account' has a private field and can only be built by the module that declares it
// GUARD-CHECK-FAIL 'd' may be read before it is assigned: type 'Account' has a private field
// GUARD-CHECK-FAIL 2 of 2 slots are left without a value: type 'Account'
// GUARD-CHECK-FAIL cannot convert uint64 to Account
// GUARD-CHECK-FAIL 'key' is a private field of 'InstructionAccount'
// GUARD-CHECK-FAIL 'writable' is a private field of 'InstructionAccount'
// GUARD-CHECK-FAIL 'signer' is a private field of 'InstructionAccount'
// GUARD-CHECK-FAIL 2 of 2 slots are left without a value: type 'InstructionAccount'
// GUARD-CHECK-FAIL 'q' may be read before it is assigned: type 'InstructionAccount'
// An Account is the address of a record the runtime parsed into the input, and an InstructionAccount the key
// of one: both are built only inside std/solana/core, from an account index the runtime holds, so an author's
// literal, `as`, generic helper, unassigned local or short array builds neither, from the barrel or from core.
// RED MEANS: an author writes `{ address: 0x400000010 }` or `{ key: 0x400000010, .. }` and the runtime reads
// that number as an input record when it reads the account or builds a CPI (an access violation, or a mid-record
// address accepted and the CPI started).
import { Account, InstructionAccount, CpiAccount, CpiInstruction, accountAt, invokeCpi } from "std/solana"; // GUARD-REFUSED
import { Account as Direct, InstructionAccount as DirectMeta } from "std/solana/core";

function build<T>(): T {
	return { address: 0x400000010 } as T; // GUARD-REFUSED
}

function forged(held: Account): void {
	const a: Account = { address: 0x400000010 }; // GUARD-REFUSED
	const b = { address: 0x400000010 } as Account; // GUARD-REFUSED
	const c = {} as Account; // GUARD-REFUSED
	let d: Account;
	const e = d.key(); // GUARD-REFUSED
	const f: Direct = { address: 0x400000010 }; // GUARD-REFUSED
	const g = build<Account>();
	const h: Account[2] = []; // GUARD-REFUSED
	const j = (0x400000010 as uint64) as Account; // GUARD-REFUSED
	const k = held.address; // GUARD-REFUSED
	const m: InstructionAccount = { key: 0x400000010, writable: 1, signer: 0 }; // GUARD-REFUSED
	const n: DirectMeta = { key: 0x400000010, writable: 1, signer: 0 }; // GUARD-REFUSED
	const o = { key: 0x400000010, writable: 1, signer: 0 } as InstructionAccount; // GUARD-REFUSED
	const p: InstructionAccount[2] = []; // GUARD-REFUSED
	let q: InstructionAccount;
	const r = q.pubkey(); // GUARD-REFUSED
	const s = InstructionAccount.writable(held).key; // GUARD-REFUSED
}
