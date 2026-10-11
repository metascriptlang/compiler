import { ProgramError, account, failWith, instructionData } from "std/solana";
import { DelegationAccounts, DelegationConfig } from "std/solana/magicblock";
import { delegateAt } from "std/solana/delegation";
import { SeedSlice, seedBytes, seedText } from "std/solana/seed";

// data[0]: 0 signs with the pet's mint read from its own data, 1 with a copy in a local; data[1]: the bump.
function step(): Result<uint64, ProgramError> {
	const shape = try instructionData().readU8(0);
	const bump = try instructionData().readU8(1);
	const delegation: DelegationAccounts = {
		payer: try account(0),
		delegated: try account(1),
		ownerProgram: try account(2),
		buffer: try account(3),
		delegationRecord: try account(4),
		delegationMetadata: try account(5),
		systemProgram: try account(6),
	};
	const held = delegation.delegated.data();
	const inside: SeedSlice = { address: held.address, length: 32 };
	if (shape == 0) { return delegateAt(delegation, [seedText("pet"), inside], bump, DelegationConfig.anyValidator()); }
	let local: uint8[32] = [];
	for (let index: uint64 = 0; index < 32; index++) { local[index] = try held.readU8(index); }
	return delegateAt(delegation, [seedText("pet"), seedBytes(local)], bump, DelegationConfig.anyValidator());
}

function main(): void {
	const result = step();
	if (!result.ok) { failWith(result.error); }
}
main();
