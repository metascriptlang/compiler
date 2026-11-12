// @stdout: freed 2000000 objects of six int64 fields, at least 80 MB returned while idle: true
// @skip-js: binds the C fixture resident.c, which reads this process's resident memory
// @xfail(san): the SAN build allocates through ASan's malloc, which keeps freed pages; this program measures the region heap
// @skip-raiser: binds the C fixture resident.c, which has no Raiser host bridge
// note: the region heap never gave back a page that held small cells (the array of 2000000
//   references went back, at most 32 MB with its earlier copies, and the objects' pages stayed
//   resident); a small chunk whose cells are all free now joins the big chunks once it stayed
//   empty for the return age, 10 to 11 s after the first loop turn that found it empty, and its
//   pages go back with them.
@include("../idleProgramReturnsFreedPages/resident.h")
@compile("../idleProgramReturnsFreedPages/resident.c")
extern function probeResidentKb(): int64;

class Record {
	a: int64 = 0;
	b: int64 = 0;
	c: int64 = 0;
	d: int64 = 0;
	e: int64 = 0;
	f: int64 = 0;
}

function churn(): int32 {
	let held: Record[] = [];
	for (let i: int32 = 0; i < 2000000; i++) held.push(new Record());
	return held.length;
}

function idle(ms: int32): Promise<void> {
	return new Promise<void>((resolve) => { setTimeout((): void => { resolve(); }, ms); });
}

const freed = churn();
const afterFree = probeResidentKb();
await idle(15000);
const afterIdle = probeResidentKb();
console.log(`freed ${freed} objects of six int64 fields, at least 80 MB returned while idle: ${afterFree - afterIdle >= 80 * 1024}`);
