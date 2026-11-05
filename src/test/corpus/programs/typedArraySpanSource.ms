// @stdout: sum 6 len 3
// @stdout: write 1,9,3 sub 9,3 off 1
// @stdout: through sub 1,7,8 buffer 0,1,7,8
// @stdout: empty 0 of 0
// note: a Uint8Array passes as a Span<uint8> with no copy: a read sees the view's bytes, a write through the span lands in the typed array and its buffer, and a subarray's span starts at its byte offset.

function sum(xs: Readonly<Span<uint8>>): number {
	let total = 0;
	for (let i = 0; i < xs.length; i++) total += xs[i];
	return total;
}

function setAt(xs: Span<uint8>, i: number, value: uint8): void {
	xs[i] = value;
}

function viewOf(buf: ArrayBuffer): Uint8Array {
	return new Uint8Array(buf, 1, 3);
}

const a = new Uint8Array([1, 2, 3]);
console.log(`sum ${sum(a)} len ${a.length}`);

setAt(a, 1, 9);
const s = a.subarray(1);
console.log(`write ${a.join(",")} sub ${s.join(",")} off ${s.byteOffset}`);

const buf = new ArrayBuffer(4);
const v = viewOf(buf);
v[0] = 1;
setAt(v.subarray(1), 0, 7);
setAt(viewOf(buf), 2, 8);
console.log(`through sub ${v.join(",")} buffer ${new Uint8Array(buf).join(",")}`);

const e = new Uint8Array(0);
console.log(`empty ${sum(e)} of ${e.length}`);
