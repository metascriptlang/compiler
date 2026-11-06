// INVARIANT: ULTRALOCK M9. On a native desktop target, managed memory (msMemAlloc, msRealloc,
//   msMemFree) comes from the region heap, not from libc: every cell sits in a heap page whose
//   header names its size class and its owning region.
// RED MEANS: the managed entries fell back to libc malloc, so frees from other threads and the
//   allocator's measured costs no longer apply.
// GUARD-TSAN
@compile("./fixtures/managedHeapChecks.c", "-O2");
@include("./fixtures/managedHeapChecks.h");

extern function msManagedHeapChecks(): int32;

if (msManagedHeapChecks() != 0) {
	throw new Error("managed allocations did not come from the region heap");
}
console.log("GUARD-OK");
