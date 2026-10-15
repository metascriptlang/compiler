// GUARD-OS solana
// GUARD-CHECK-FAIL instruction<CaseOp>(): members 'TakeAll' and 'takeAll' have the same discriminator, of the instruction names 'take_all' and 'take_all'
// GUARD-CHECK-FAIL instruction<AcronymOp>(): members 'InitNFT' and 'InitNft' have the same discriminator, of the instruction names 'init_nft' and 'init_nft'
// GUARD-CHECK-FAIL instruction<SpreadOp>(): members 'Close' and 'close' have the same discriminator, of the instruction names 'close' and 'close'
// instruction<Op>() picks the first member whose discriminator the instruction data carries, and
// a discriminator hashes the snake_case of the member's name: two members that differ only in the
// case of a letter or of an acronym, next to each other or not, are one instruction.
// RED MEANS: instruction<Op>() compiled an enum whose later member no instruction data selects.
import { ProgramError, failWith, instruction } from "std/solana";

export enum CaseOp { Make, TakeAll, takeAll }
export enum AcronymOp { InitNFT, InitNft }
export enum SpreadOp { Close, Open, close }

function byCase(): Result<uint64, ProgramError> {
	return match (try instruction<CaseOp>()) {
		CaseOp.Make => Result.ok(0),
		CaseOp.TakeAll => Result.ok(1),
		CaseOp.takeAll => Result.ok(2),
	};
}

function byAcronym(): Result<uint64, ProgramError> {
	return match (try instruction<AcronymOp>()) {
		AcronymOp.InitNFT => Result.ok(0),
		AcronymOp.InitNft => Result.ok(1),
	};
}

function bySpread(): Result<uint64, ProgramError> {
	return match (try instruction<SpreadOp>()) {
		SpreadOp.Close => Result.ok(0),
		SpreadOp.Open => Result.ok(1),
		SpreadOp.close => Result.ok(2),
	};
}

function main(): void {
	const first = byCase();
	if (!first.ok) { failWith(first.error); }
	const second = byAcronym();
	if (!second.ok) { failWith(second.error); }
	const third = bySpread();
	if (!third.ok) { failWith(third.error); }
}

main();
