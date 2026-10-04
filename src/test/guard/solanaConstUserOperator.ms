// GUARD-OS solana
// A module-level `const` whose initializer goes through a user operator on a built-in
// type is a compile-time constant under --os=solana: the declared routine runs while
// compiling (Nim semConstExpr: getConstExpr folds magics, evalConstExpr runs any other
// routine in the VM, sem.nim:492-512), so the binding is read-only data. Covers the
// int32 `/`, the int64 `/` overload of the same name, the int64 `%`, and a user
// operator nested under a built-in `*`. Each *_OK indexes PROOF with the value minus
// the user routine's result, so any other value is out of range and fails the build.
// RED MEANS: the const is FREESTANDING E02 again (the user operator stopped running at
// compile time), or it folded through the built-in operator or the wrong overload.
import * as ops from "./fixtures/solanaConstOperators";
import { logU64 } from "std/solana";

const ONE: int32 = 64;
const WIDE: int64 = 640;
const STEP: int32 = ONE / 8;
const HALF: int64 = WIDE / 8;
const LEFT: int64 = WIDE % 7;
const NESTED: int32 = (ONE / 8) * 2;
const PROOF: uint8[4] = [1, 2, 3, 4];
const STEP_OK: uint8 = PROOF[STEP - 6408];
const HALF_OK: uint8 = PROOF[HALF - 647];
const LEFT_OK: uint8 = PROOF[LEFT - 75];
const NESTED_OK: uint8 = PROOF[NESTED - 12813];

function main(): void {
	logU64((STEP_OK + HALF_OK + LEFT_OK + NESTED_OK) as uint64);
}
main();
