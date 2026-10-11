import { entry } from "../../../examples/anchorBench/vault/program";
import { ProgramError, Pubkey, SYSTEM_PROGRAM_ID, findProgramAddressOf, instructionDiscriminator, leBytes } from "std/solana";
import { HostAccount, invocations, run } from "std/solana/host";

function vaultProgram(): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = 9;
	return key;
}

function vaultUser(): Pubkey {
	let key = Pubkey.zero();
	key.bytes[0] = 1;
	return key;
}

function vaultAccounts(deposit: boolean): HostAccount[] {
	const derived = findProgramAddressOf(vaultProgram(), ["vault", vaultUser()]);
	if (!derived.ok) { throw new Error("vault fixture PDA could not be derived"); }
	const user: HostAccount = {
		key: vaultUser(), owner: SYSTEM_PROGRAM_ID, lamports: 1000, data: [],
		signer: true, writable: true, executable: false,
	};
	const vault: HostAccount = {
		key: derived.value.key, owner: vaultProgram(), lamports: 200, data: [],
		signer: false, writable: true, executable: false,
	};
	const accounts = [user, vault];
	if (deposit) {
		accounts.push({ key: SYSTEM_PROGRAM_ID, owner: Pubkey.zero(), lamports: 1, data: [],
			signer: false, writable: false, executable: true });
	}
	return accounts;
}

function vaultInstruction(name: string, amount: uint64): uint8[] {
	const bytes: uint8[] = [];
	for (const byte of instructionDiscriminator(name).bytes) { bytes.push(byte); }
	for (const byte of leBytes(amount)) { bytes.push(byte); }
	return bytes;
}

test "vault deposit transfers the instruction amount to the verified PDA" {
	const accounts = vaultAccounts(true);
	assert run(vaultProgram(), accounts, vaultInstruction("Deposit", 37), entry).result == 0;
	assert accounts[0].lamports == 963 && accounts[1].lamports == 237;
	const calls = invocations();
	assert calls.length == 1 && calls[0].program == SYSTEM_PROGRAM_ID;
	assert calls[0].data[0] == 2 && calls[0].data[4] == 37;
}

test "vault withdraw returns the instruction amount to its signer" {
	const accounts = vaultAccounts(false);
	assert run(vaultProgram(), accounts, vaultInstruction("Withdraw", 37), entry).result == 0;
	assert accounts[0].lamports == 1037 && accounts[1].lamports == 163;
}

test "vault refuses a PDA derived for another signer before moving funds" {
	const accounts = vaultAccounts(true);
	accounts[0].key.bytes[0] = 2;
	assert run(vaultProgram(), accounts, vaultInstruction("Deposit", 37), entry).result == ProgramError.constraintSeeds().code;
	assert accounts[0].lamports == 1000 && accounts[1].lamports == 200;
}

test "vault refuses an unsigned withdraw before moving funds" {
	const accounts = vaultAccounts(false);
	accounts[0].signer = false;
	assert run(vaultProgram(), accounts, vaultInstruction("Withdraw", 37), entry).result == ProgramError.accountNotSigner().code;
	assert accounts[0].lamports == 1000 && accounts[1].lamports == 200;
}

test "vault refuses a truncated amount before account checks" {
	const accounts = vaultAccounts(false);
	const data: uint8[] = [];
	for (const byte of instructionDiscriminator("Withdraw").bytes) { data.push(byte); }
	assert run(vaultProgram(), accounts, data, entry).result == ProgramError.instructionDidNotDeserialize().code;
	assert accounts[0].lamports == 1000 && accounts[1].lamports == 200;
}
