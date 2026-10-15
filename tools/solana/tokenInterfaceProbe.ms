import {
	ProgramError,
	account,
	external,
	externalMutable,
	failWith,
	instructionData,
} from "std/solana";
import {
	InterfaceMint,
	InterfaceTokenAccount,
	Mint,
	TokenAccount,
	transferTokens,
} from "std/solana/token";

function step(): Result<uint64, ProgramError> {
	const input = instructionData();
	const op = try input.readU8(0);
	if (op == 0) { const _verified = try external<Mint>(0); }
	if (op == 1) { const _verified = try external<InterfaceMint>(0); }
	if (op == 2) { const _verified = try external<TokenAccount>(0); }
	if (op == 3) { const _verified = try external<InterfaceTokenAccount>(0); }
	if (op == 4) {
		const from = try externalMutable<TokenAccount>(0);
		const to = try externalMutable<TokenAccount>(1);
		return transferTokens(from, to, try external<Mint>(2), try account(3), try input.readU64(1));
	}
	if (op == 5) {
		const from = try externalMutable<InterfaceTokenAccount>(0);
		const to = try externalMutable<InterfaceTokenAccount>(1);
		return transferTokens(from, to, try external<InterfaceMint>(2), try account(3), try input.readU64(1));
	}
	return Result.ok(0);
}

function main(): void {
	const result = step();
	if (!result.ok) { failWith(result.error); }
}
main();
