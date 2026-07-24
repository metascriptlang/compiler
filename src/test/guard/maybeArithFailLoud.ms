// maybeArithFailLoud — arithmetic on a value-Maybe must FAIL LOUD at the checker.
//
// After the HashMap/Map .get() → `V | null` migration, `m.get(k)` is a value-Maybe.
// Using it directly in numeric arithmetic (`sum + m.get(k)`) must be a clean checker
// error, NOT a cryptic `int + struct` leak to clang. Guards checkExprPass's arithmetic
// null-guard (inferBinaryOp path) — if that rule is dropped, this compiles clean and the
// errorcheck runner reports the regression.
//
// GUARD-CHECK-FAIL operand of '+' is possibly null
// GUARD-CHECK-FAIL operand of '<' is possibly null

import { Map } from "std/core/struct";

function main(): void {
	const m = new Map<int32, int32>();
	m.set(1 as int32, 10 as int32);
	let sum = 0;
	for (const k of m.toItems()) { sum = sum + m.get(k); }
	let hits = 0;
	for (const k of m.toItems()) { if (m.get(k) < 5) { hits = hits + 1; } }
	console.log(`${sum} ${hits}`);
}
main();
