// GUARD-OS solana
// A `const` that names another aggregate `const`, one of its elements or one of its
// fields folds to the constant it denotes (Nim semConstExpr → getConstExpr: a const
// symbol is its folded definition, foldArrayAccess, foldFieldAccess), so it is
// read-only data like a literal one: same module, imported, an alias of an alias,
// an aggregate holding an alias, and a scalar read out of one.
// RED MEANS: an alias of an aggregate const is FREESTANDING E02 again — the const
// initializer fold stopped following const bindings, elements or fields.
import { ODDS } from "./fixtures/solanaTables";
import { instructionData, logU64 } from "std/solana";

struct KnobAlias { min: uint64; bump: uint64; }

const TABLE: uint8[4] = [3, 5, 7, 9];
const TABLE_ALIAS: uint8[4] = TABLE;
const TABLE_ALIAS2: uint8[4] = TABLE_ALIAS;
const ODDS_ALIAS: uint64[4] = ODDS;
const KNOB: KnobAlias = { min: 2, bump: 40 };
const KNOB_ALIAS: KnobAlias = KNOB;
const ROWS: KnobAlias[2] = [KNOB, { min: 4, bump: 50 }];
const SECOND: uint8 = TABLE[1];
const BUMP: uint64 = KNOB.bump;
const SPAN: uint64 = ODDS[3] - ODDS[0];

function main(): void {
	const idx = (instructionData().length % 4) as int32;
	logU64(TABLE_ALIAS2[idx] as uint64 + ODDS_ALIAS[idx]);
	logU64(KNOB_ALIAS.min + ROWS[0].bump + ROWS[1].bump);
	logU64(SECOND as uint64 + BUMP + SPAN);
}
main();
