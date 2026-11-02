// @exit: 7
// @stdout: aborted M1
// @skip-js: binds the C fixture stale.c, which drives the cycle-root registry directly
// @skip-raiser: binds the C fixture stale.c, whose msTestFreeRootOfExitedWorker has no Raiser host bridge

@include("../rootFreedOutsideItsExecutorFailsLoud/stale.h")
@compile("../rootFreedOutsideItsExecutorFailsLoud/stale.c")
extern function msTestFreeRootOfExitedWorker(ownRoots: int32): int32;

console.log(`roots left ${msTestFreeRootOfExitedWorker(0)}`);
