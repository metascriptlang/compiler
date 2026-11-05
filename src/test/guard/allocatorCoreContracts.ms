// GUARD-OS bare
// GUARD-ASAN
@compile("./fixtures/allocatorCoreChecks.c", "-O3");
@include("./fixtures/bareHeapChecks.h");

extern function msAllocatorCoreChecks(): int32;

if (msAllocatorCoreChecks() != 0) {
	throw new Error("allocator core contracts failed");
}
console.log("GUARD-OK");
