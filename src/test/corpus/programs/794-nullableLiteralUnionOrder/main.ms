// @stdout: literal-union-order ok=row-reverse
// @exit: 0
// note: Maybe cache identity for a string-literal union written in a different ORDER
// (checker/types.ms maybeCacheKey, slu arm). LibA declares `"column" | "column-reverse" | "row" |
// "row-reverse"`, LibB the same four in another order; the checker calls them one type, so the
// nullable carrier must be one too. While the arm appended members in declaration order the two
// keys differed and clang refused: "assigning to 'Maybe_slu_column6_columnreverse14_row3_rowreverse11'
// from incompatible type 'Maybe_slu_row3_column6_rowreverse11_columnreverse14'" — checker silent.
// Sighted building neon against yoga 2026-09-21 (FlexDirection and Justify, four of eight errors).
// Fix: sort the member keys before joining. Sibling of 793 (same alias, same order) and
// 200-maybeUnionIdentity (anonymous payloads).

import { StyleA, makeA } from "./orderLibA";
import { StyleB, makeB } from "./orderLibB";

function main(): void {
	const a: StyleA = makeA();
	const b: StyleB = makeB();
	a.dir = b.dir;
	console.log(`literal-union-order ok=${a.dir != null ? a.dir as string : "none"}`);
}
main();
