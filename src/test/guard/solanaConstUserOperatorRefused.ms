// GUARD-OS solana
// GUARD-CHECK-FAIL solanaConstUserOperatorRefused.ms:12:7
// GUARD-CHECK-FAIL solanaConstUserOperatorRefused.ms:13:7
// GUARD-CHECK-FAIL is not a compile-time constant, so the binding needs writable static storage
// A user operator that cannot run while compiling (it reads the instruction data) and a
// plain function call both leave a Solana module const FREESTANDING E02.
// RED MEANS: such a const was accepted, or it lost its E02.
import { logU64, instructionData } from "std/solana";
function `/`(this a: int32, b: int32): int32 { return instructionData().length as int32; }
function twice(n: int32): int32 { return n * 2; }
const ONE: int32 = 64;
const STEP: int32 = ONE / 8;
const CALLED: int32 = twice(ONE);
function main(): void { logU64((STEP + CALLED) as uint64); }
main();
