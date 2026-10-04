// GUARD-OS solana
// A module `const` sized array, struct literal and T[N] of structs whose leaves
// are scalar literals are read-only data: the definition is emitted as C `const`
// with a braced initializer (Nim genConstDefinition), lands in .rodata and the
// SBF link keeps it. Same module and imported (`getConstExpr`, NIM-REF CK-120).
// RED MEANS: genGlobalVar stopped emitting the braced const, or the E02 gate and
// the emission predicate drifted apart — run /trace-nim on the aggregate const.
import { ODDS } from "./fixtures/solanaTables";
import { instructionData, logU64 } from "std/solana";

struct KnobRod { min: uint64; bump: uint64; }

const TABLE: uint8[4] = [3, 5, 7, 9];
const KNOB: KnobRod = { min: 2, bump: 40 };
const ROWS: KnobRod[2] = [{ min: 1, bump: 10 }, { min: 4, bump: 50 }];

function main(): void {
	const idx = (instructionData().length % 4) as int32;
	logU64(TABLE[idx] as uint64 + ODDS[idx]);
	logU64(KNOB.min + KNOB.bump + ROWS[1].bump);
}
main();
