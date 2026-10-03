// Parked at inbox card 2026-09-27-private-macro-bound-callee-links-externally.md

import { twice, outer, outer2 } from "./macroBindingFixture";

function dbl(value: string): string { return "caller " + value; }

function inner(value: string): string { return "caller macro " + value; }

test "macro expansion identity: declaration-module symbols resist caller shadowing" {
	assert twice(21) == 42;
	assert outer(7) == 14;
	assert outer2(0) == 42;
	assert dbl("x") == "caller x";
	assert inner("y") == "caller macro y";
	{ const dbl: int32 = 9; assert twice(8) + dbl == 25; }
}
