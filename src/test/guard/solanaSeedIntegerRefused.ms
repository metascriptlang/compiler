// GUARD-OS solana
// GUARD-CHECK-FAIL seed 2 has type uint64
// GUARD-CHECK-FAIL seed 1 has type boolean
// GUARD-CHECK-FAIL seed 2 has type Pair
// GUARD-CHECK-FAIL seed 3 has type int32
// GUARD-CHECK-FAIL write an integer seed as bytes: `[x]` for a uint8, `leBytes(x)` for a wider integer
// A seed is a string, a byte array, a Pubkey or an account. An integer, a boolean and a
// struct are refused where the list is written, whichever call takes it.
// RED MEANS: seedTable accepted a seed it cannot hand to the syscall as bytes.
import {
	failWith,
	findProgramAddress,
	programAddress,
	programAddressOf,
	pubkeyOf,
} from "std/solana";

struct Pair {
	left: uint64;
	right: uint64;
}

function main(): void {
	const id: uint64 = 7;
	const flag: boolean = true;
	const pair: Pair = { left: 1, right: 2 };
	const count: int32 = 3;
	const program = pubkeyOf("9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu");
	const byInteger = findProgramAddress(["pet", id]);
	const byBoolean = programAddress([flag]);
	const byStruct = findProgramAddress(["pet", pair]);
	const bySigned = programAddressOf(program, ["pet", [1], count]);
	if (!byInteger.ok) { failWith(byInteger.error); }
	if (!byBoolean.ok) { failWith(byBoolean.error); }
	if (!byStruct.ok) { failWith(byStruct.error); }
	if (!bySigned.ok) { failWith(bySigned.error); }
}

main();
