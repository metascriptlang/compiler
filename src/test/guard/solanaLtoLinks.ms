// GUARD-OS solana --danger
// A --danger build for SBF takes LTO (the capability table, BUILD-PERF.md) and must link:
// its bitcode is merged and compiled to an SBF object before ld.lld meets platform-tools'
// compiler_builtins, which ld.lld refuses beside raw bitcode ("is incompatible with").
import { instructionData, logU64 } from "std/solana";
import * as arithmetic from "std/solana/arithmetic";

function scaled(value: int64, divisor: int64): int64 {
	return value / divisor + value % 8;
}

function main(): void {
	const length = instructionData().length as int64;
	logU64(scaled(length * 1000 - 7, length + 3) as uint64);
}

main();
