// INVARIANT: calloc skips zeroing only memory that has never been handed out since it came
//   from a page source that returns zero pages: a fresh small cell, a fresh big chunk and its
//   split remainder; a freed cell, a freed or coalesced big chunk and a small chunk carved
//   from a reused page are zeroed every time.
// RED MEANS: calloc handed out reused memory with stale bytes, or zeroed fresh memory again
//   (the page source here fills pages with 0xa5 while claiming zero, so a skip shows).
// GUARD-OS bare
// GUARD-ASAN
@compile("./fixtures/allocatorZeroChecks.c", "-O3");
@include("./fixtures/bareHeapChecks.h");

extern function msAllocatorZeroChecks(): int32;

if (msAllocatorZeroChecks() != 0) {
	throw new Error("allocator zero contracts failed");
}
console.log("GUARD-OK");
