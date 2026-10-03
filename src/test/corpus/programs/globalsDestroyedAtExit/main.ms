// @stdout: now 4 local 2 current 3 shared 2 3 7
// @exit: 0
// note: module-level values — an exported alias of another global, a class instance, a reassigned `let` and the top level's temporaries — are destroyed when the program ends; a local of the same types is destroyed at its scope exit, so the SAN ledger checks the exact balance. Reference: injectdestructors pVarTopLevel + cgen finalCodegenActions (NIM-REF AN-22).

import { Box, shared, owned, boxes } from "./shelf";

const holder = new Box(7);
let current: Box[] = boxes(2);
current = boxes(3);

function local(): int32 {
	const tmp = boxes(2);
	return tmp.length;
}

console.log(`now ${boxes(4).length} local ${local()} current ${current.length} shared ${shared.length} ${owned[0].v} ${holder.v}`);
