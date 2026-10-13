@include("runtime/solana/solana.h");

import { ProgramError, account, createAccount, failWith, instructionData, logU64, minimumBalance, programId } from "std/solana";

extern function msSolLoadU64(address: uint64): uint64;

function growAfterCreate(space: uint64, target: uint64, freshIndex: int32, neighbourIndex: int32): Result<uint64, ProgramError> {
	const payer = try account(0);
	const fresh = try account(freshIndex);
	const neighbour = try account(neighbourIndex);
	logU64(msSolLoadU64(neighbour.address + 8));
	logU64(neighbour.lamports());
	const _created = try createAccount(payer, fresh, minimumBalance(20480), space, programId());
	const grown = fresh.resize(target);
	logU64(grown.ok ? 1 : 0);
	logU64(msSolLoadU64(neighbour.address + 8));
	logU64(neighbour.lamports());
	return Result.ok(0);
}

function dispatch(): Result<uint64, ProgramError> {
	const data = instructionData();
	const space = (try data.readU16(0)) as uint64;
	const target = (try data.readU16(2)) as uint64;
	const freshIndex = (try data.readU8(4)) as int32;
	const neighbourIndex = (try data.readU8(5)) as int32;
	return growAfterCreate(space, target, freshIndex, neighbourIndex);
}

function main(): void {
	const result = dispatch();
	if (!result.ok) { failWith(result.error); }
}
main();
