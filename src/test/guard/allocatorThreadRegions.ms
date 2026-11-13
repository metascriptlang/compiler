// INVARIANT: ULTRALOCK M10 and M11. Each thread allocates from its own region; a free from
//   another thread reaches the owner as a pointer in a batch, without a write to the block, and
//   the owner frees it and reuses those cells and big chunks; a second free is refused once,
//   whichever threads made the two frees and whether they raced; a small chunk another thread
//   emptied returns to the big-chunk pool on the owner's next return; a runtime thread that
//   exits releases its region, whose cells stay valid and whose pending frees the next thread
//   adopts; a foreign thread that exits without a release
//   leaves its cells freeable from any thread.
// RED MEANS: a remote free touched the owner's region or the block, the owner never took remote
//   frees back, a second free went through or was refused twice,
//   a remotely emptied small chunk kept its page,
//   a retired region was lost or adopted twice, or TSan saw a race on the shared lists.
// GUARD-TSAN
@compile("./fixtures/allocatorThreadChecks.c", "-O2");
@include("./fixtures/allocatorThreadChecks.h");

extern function msAllocatorThreadChecks(): int32;

if (msAllocatorThreadChecks() != 0) {
	throw new Error("allocator thread regions failed");
}
console.log("GUARD-OK");
