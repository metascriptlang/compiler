// nim-guard: one small-object free list per thread, shared by every C unit.
//
// Reference: one `allocator` threadvar per thread (lib/system/mmdisp.nim:87); every
// module allocates and frees through it, so a block one module frees is the next
// block of that size any module on the thread receives.
// Proven red with the slab declared `static` in runtime/drc.h: the block freed in
// slabUnitB.c stays in that unit's list and slabUnitA.c's next allocation mallocs.
//
// RED MEANS each C unit got its own slab again; run /trace-nim on msSlabTLS
// (runtime/drc.{h,c}) against mmdisp.nim.

@compile("./fixtures/slabUnitA.c");
@compile("./fixtures/slabUnitB.c");

import { msTestSlabReusedAcrossUnits } from "./fixtures/slabUnits.h";

function main(): void {
	if (!msTestSlabReusedAcrossUnits()) throw new Error("a block freed in one C unit was not reused by another");
	console.log("slab-shared ok");
}
main();
