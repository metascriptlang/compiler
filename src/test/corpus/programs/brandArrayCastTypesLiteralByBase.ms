// Parity program — `[...] as B` with a brand B over an array types the literal by B's array base,
// as `as uint8[]` does, so the elements keep their width and the cast adds only the brand.
// Axes: a uint8 and an int16 base, an empty literal, a struct field, a generic `T[]` brand and a
// brand over a literal passed on as its base.
//
// @stdout: 60 20 3
// @stdout: 298 -2
// @stdout: 0
// @stdout: 9 4
// @stdout: 7 8 15
// @exit: 0
type Bytes = uint8[] & { __brand: "Bytes" };
type Words = int16[] & { __brand: "Words" };
type Tagged<T> = T[] & { __brand: "Tagged" };

struct Packet {
	body: Bytes;
	tail: Words;
}

function sumOf(xs: uint8[]): int32 {
	let sum: int32 = 0;
	for (const b of xs) sum += b;
	return sum;
}

const bytes = [10, 20, 30] as Bytes;
let total = 0;
for (const b of bytes) total += b;
console.log(total, bytes[1], bytes.length);

const words = [300, -2] as Words;
console.log(words[0] + words[1], words[1]);

const empty = [] as Bytes;
console.log(empty.length);

const packet: Packet = { body: [4, 5] as Bytes, tail: [1000, -1000, 3, 1] as Words };
console.log(packet.body[0] + packet.body[1], packet.tail.length);

const tagged = [7, 8] as Tagged<uint8>;
console.log(tagged[0], tagged[1], sumOf(tagged));
