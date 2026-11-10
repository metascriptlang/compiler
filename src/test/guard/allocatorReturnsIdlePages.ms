// INVARIANT: an owner returns the pages of a dirty free big chunk to the OS once the chunk stayed
//   unused for the return age, on any loop turn, and all of them when it releases its region,
//   keeping each chunk's first page. A split's rest keeps the chunk's age and two chunks joined
//   keep the larger one's. A take or an in-place grow re-arms only the front it uses of a
//   discarded chunk; a discarded chunk joins only discarded chunks, is reused before any byte of
//   it is touched again and is never treated as zeroed; a remote big free racing the return
//   lands safely.
// RED MEANS: a discarded page was touched before reuse (the page source faults), calloc handed
//   out bytes the OS never cleared (the page source leaves 0xa5), a header page was discarded,
//   a chunk went back before its age or stayed after it, a take re-armed pages it did not use,
//   or TSan saw a race between a remote free and the return.
// GUARD-TSAN
@compile("./fixtures/allocatorIdleChecks.c", "-O2");
@include("./fixtures/allocatorIdleChecks.h");

extern function msAllocatorIdleChecks(): int32;

if (msAllocatorIdleChecks() != 0) {
	throw new Error("allocator idle return failed");
}
console.log("GUARD-OK");
