// INVARIANT: an owner returns the pages of a dirty free big chunk to the OS once the chunk stayed
//   unused for the return age, on any loop turn, and all of them when it releases its region,
//   keeping each chunk's first page. A split's rest keeps the chunk's age and two chunks joined
//   keep the larger one's. A take or an in-place grow re-arms only the front it uses of a
//   discarded chunk; a discarded chunk joins only discarded chunks, is reused before any byte of
//   it is touched again and is never treated as zeroed; a remote big free racing the return
//   lands safely. A small chunk whose cells are all on its own free list waits the return age,
//   then joins the big chunks and goes back as they do; one with a cell in another thread's run
//   or in its owner's remote cache stays until that cell is home. A timed return does one turn's
//   share of this work (remote cells routed home, aged chunks released, pages discarded) and the
//   next loop turn takes the rest.
// RED MEANS: a discarded page was touched before reuse (the page source faults), calloc handed
//   out bytes the OS never cleared (the page source leaves 0xa5), a header page was discarded,
//   a chunk went back before its age or stayed after it, a take re-armed pages it did not use,
//   TSan saw a race between a remote free and the return, an emptied small chunk kept its page,
//   a small chunk left while one of its cells was still away, one loop turn did more than its
//   share, or work was left that no later turn was due for.
// GUARD-TSAN
@compile("./fixtures/allocatorIdleChecks.c", "-O2");
@include("./fixtures/allocatorIdleChecks.h");

extern function msAllocatorIdleChecks(): int32;

if (msAllocatorIdleChecks() != 0) {
	throw new Error("allocator idle return failed");
}
console.log("GUARD-OK");
