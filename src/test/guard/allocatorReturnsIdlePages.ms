// INVARIANT: an owner returns the pages of its dirty free big chunks to the OS when it idles or
//   releases its region, keeping each chunk's first page; a discarded chunk is reused before any
//   byte of it is touched again (taken, split, coalesced or grown into) and is never treated as
//   zeroed; a remote big free racing the return lands safely.
// RED MEANS: a discarded page was touched before reuse (the page source faults), calloc handed
//   out bytes the OS never cleared (the page source leaves 0xa5), a header page was discarded,
//   or TSan saw a race between a remote free and the return.
// GUARD-TSAN
@compile("./fixtures/allocatorIdleChecks.c", "-O2");
@include("./fixtures/allocatorIdleChecks.h");

extern function msAllocatorIdleChecks(): int32;

if (msAllocatorIdleChecks() != 0) {
	throw new Error("allocator idle return failed");
}
console.log("GUARD-OK");
