// Parity program — an extern function declared to return a brand over an array returns the array by value
// at the C ABI, as one declared to return the array itself does, and the call's result is the brand.
// Axes: the result held in a local and iterated, stored in a struct field, and the plain array return beside it.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @xfail(raiser): raiser runtime error: Unknown host function: corpusBrandMake
// @stdout: 4 3 10
// @stdout: 2 5
// @stdout: 3 6
// @exit: 0
type Bytes = uint8[] & { __brand: "Bytes" };

@include("./ffi.h");
extern function corpusBrandMake(n: int64): Bytes;
extern function corpusPlainMake(n: int64): uint8[] from "corpusBrandMake";

struct Holder {
	data: Bytes;
}

const bytes = corpusBrandMake(4);
let sum = 0;
for (const b of bytes) sum += b;
console.log(bytes.length, bytes[2], sum);

const holder: Holder = { data: corpusBrandMake(2) };
console.log(holder.data.length, holder.data[0] + holder.data[1] + 2);

const plain = corpusPlainMake(3);
console.log(plain.length, plain[0] + plain[1] + plain[2]);
