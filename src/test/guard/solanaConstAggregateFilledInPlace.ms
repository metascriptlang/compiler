// GUARD-OS solana
// A function's `const` aggregate whose initializer reads a run-time value is built in place, field
// by field, so it is writable storage on the frame; only a fully constant one is read-only data.
// RED MEANS: the in-place build left the binding `const`, the read-only data rule took the empty
// shell for a constant table, and clang refused the field writes into `static const` storage.
import { instructionData, logU64 } from "std/solana";

struct Slot { a: uint64; b: uint64; }
struct Pair { left: Slot; right: Slot; }

function sum(n: uint64): uint64 {
	const items: Slot[2] = [{ a: n, b: n + 1 }, { a: 2, b: 3 }];
	const pair: Pair = { left: { a: n, b: 1 }, right: { a: 4, b: n } };
	const table: Slot[2] = [{ a: 5, b: 6 }, { a: 7, b: 8 }];
	return items[0].a + items[1].b + pair.left.a + pair.right.b + table[1].a;
}

logU64(sum(instructionData().length as uint64));
