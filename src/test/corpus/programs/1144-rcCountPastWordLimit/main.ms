// @xfail(raiser): raiser runtime error: Unknown host function: corpus1144NearWrap
// Parity program — a live object's reference count keeps counting past the width of a 32-bit
// word. The helper moves the count to 4 below 2^32 in place of four billion real references;
// eight real references then cross that boundary, plain and atomic, and leaving them must not
// run the destroy hook of an object that is still held.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @stdout: plain destroyed 0 v 42
// @stdout: atomic last 0 v 42
// @stdout: end destroyed 2
// @exit: 0

@include("./ffi.h");

extern function corpus1144NearWrap(p: Ptr<void>, sign: int64): void;
extern function corpus1144AtomicCrossings(p: Ptr<void>): int64;

class Box { v: number = 42; }

let destroyed = 0;
function onDestroy(this b: Box): void { destroyed += 1; }

function plain(): void {
	const b = new Box();
	corpus1144NearWrap(b as Ptr<void>, 1);
	const xs: Box[] = [];
	for (let i = 0; i < 8; i++) xs.push(b);
	for (let i = 0; i < 8; i++) xs.pop();
	corpus1144NearWrap(b as Ptr<void>, -1);
	console.log(`plain destroyed ${destroyed} v ${b.v}`);
}

function atomic(): void {
	const b = new Box();
	corpus1144NearWrap(b as Ptr<void>, 1);
	const last = corpus1144AtomicCrossings(b as Ptr<void>);
	corpus1144NearWrap(b as Ptr<void>, -1);
	console.log(`atomic last ${last} v ${b.v}`);
}

plain();
atomic();
console.log(`end destroyed ${destroyed}`);
