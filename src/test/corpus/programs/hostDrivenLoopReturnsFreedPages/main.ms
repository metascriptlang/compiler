// @stdout: the loop asks its host to wake within the return age: true
// @stdout: freed 64 strings of 2 MiB, at least 100 MB returned across turns that never wait: true
// @skip-js: binds the C fixture resident.c, which reads this process's resident memory
// @xfail(san): the SAN build allocates through ASan's malloc, which keeps freed pages; this program measures the region heap
// @skip-raiser: binds the C fixture resident.c, which has no Raiser host bridge
// note: a host that owns the wait (a window loop) runs the runtime's loop with a zero timeout on
//   every frame and asks msAdjustTimeout how long it may sleep. The idle clock started only in a
//   turn that waited, so such a program kept every freed page (143 MB after 2.4 s of turns, 4 MB
//   after a waiting loop) and msAdjustTimeout answered -1.
@include("runtime/promise/dispatch.h");
@include("../idleProgramReturnsFreedPages/resident.h")
@compile("../idleProgramReturnsFreedPages/resident.c")
extern function probeResidentKb(): int64;
extern function probeSleepMs(ms: int32): void;
extern function msRunOnce(timeoutMs: int32): boolean;
extern function msGetDispatcher(): Ptr<void>;
extern function msAdjustTimeout(d: Ptr<void>, pollTimeout: int32, nextTimerMs: int32): int32;

function churn(): int32 {
	let held: string[] = [];
	for (let i: int32 = 0; i < 64; i++) held.push("h".repeat(2 * 1024 * 1024));
	return held.length;
}

const freed = churn();
const afterFree = probeResidentKb();
msRunOnce(0 as int32);
const wake = msAdjustTimeout(msGetDispatcher(), -1 as int32, -1 as int32);
console.log(`the loop asks its host to wake within the return age: ${wake > 0 && wake <= 11000}`);
for (let i: int32 = 0; i < 750; i++) {
	msRunOnce(0 as int32);
	probeSleepMs(16 as int32);
}
const afterTurns = probeResidentKb();
console.log(`freed ${freed} strings of 2 MiB, at least 100 MB returned across turns that never wait: ${afterFree - afterTurns >= 100 * 1024}`);
