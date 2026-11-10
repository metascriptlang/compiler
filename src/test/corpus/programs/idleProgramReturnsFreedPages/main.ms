// @stdout: freed 64 strings of 2 MiB, at least 100 MB returned while idle: true
// @skip-js: binds the C fixture resident.c, which reads this process's resident memory
// @xfail(san): the SAN build allocates through ASan's malloc, which keeps freed pages; this program measures the region heap
// @skip-raiser: binds the C fixture resident.c, which has no Raiser host bridge
// note: the region heap kept every page it took until this program exited (RSS stayed at its
//   peak after the strings were freed); a thread now returns the pages of a free big chunk 10 to
//   11 s after the chunk went unused, here from a loop asleep on a timer.
@include("./resident.h")
@compile("./resident.c")
extern function probeResidentKb(): int64;

function churn(): int32 {
	let held: string[] = [];
	for (let i: int32 = 0; i < 64; i++) held.push("h".repeat(2 * 1024 * 1024));
	return held.length;
}

function idle(ms: int32): Promise<void> {
	return new Promise<void>((resolve) => { setTimeout((): void => { resolve(); }, ms); });
}

const freed = churn();
const afterFree = probeResidentKb();
await idle(12500);
const afterIdle = probeResidentKb();
console.log(`freed ${freed} strings of 2 MiB, at least 100 MB returned while idle: ${afterFree - afterIdle >= 100 * 1024}`);
