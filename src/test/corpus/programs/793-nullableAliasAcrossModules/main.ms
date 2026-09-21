// @stdout: nullable-alias ok=relative
// @exit: 0
// note: Maybe cache identity for a TRANSPARENT alias (checker/types.ms maybeCacheKey).
// LibA and LibB each declare `type PositionType = "static" | "relative" | "absolute"` byte for byte.
// Qualifying every named payload by its declaring module made the alias nominal in nullable position
// only, so copying `position` between the two Styles emitted two different carriers and clang refused:
// "assigning to 'Maybe_PositionType_<pathA>' from incompatible type 'Maybe_PositionType_<pathB>'" —
// the checker stayed silent. Sighted from neon 2026-09-21 (yoga/src/enums.ms vs
// neon/src/render/style.ms, nine errors, all of them nullable aliases). Fix: only Struct, Enum,
// Distinct and Result carry a declaring module into the key; a transparent alias keys structurally.

import { StyleA, makeA } from "./nullableAliasLibA";
import { StyleB, makeB } from "./nullableAliasLibB";

function main(): void {
	const a: StyleA = makeA();
	const b: StyleB = makeB();
	a.position = b.position;
	console.log(`nullable-alias ok=${a.position != null ? a.position as string : "none"}`);
}
main();
