// @stdout: 7 9 5 6 8 sum=16 7 9 11
// note: a `this` receiver typed `Span<T>` takes a sized array, a Vec, an array and a sized-array field in method form, as the free call does, and a write through it reaches the caller's storage.

function first(this storage: Span<uint8>): uint8 {
	return storage[0];
}

function put(this storage: Span<uint8>, at: int32, value: uint8): void {
	storage[at] = value;
}

function sum(this storage: Readonly<Span<uint8>>): int32 {
	let total: int32 = 0;
	for (let i = 0; i < storage.length; i++) total += storage[i] as int32;
	return total;
}

struct Frame { bytes: uint8[4]; }

let sized: uint8[4] = [7, 0, 0, 0];
let vec: Vec<uint8> = [1, 2];
const shared: uint8[] = [3, 4];
let frame: Frame = { bytes: [1, 1, 1, 1] };
const head = sized.first();
sized.put(1, 9);
vec.put(0, 5);
shared.put(1, 6);
frame.bytes.put(2, 8);
console.log(head.toString() + " " + sized[1].toString() + " " + vec[0].toString() + " " + shared[1].toString() + " " + frame.bytes[2].toString()
	+ " sum=" + sized.sum().toString() + " " + vec.sum().toString() + " " + shared.sum().toString() + " " + frame.bytes.sum().toString());
