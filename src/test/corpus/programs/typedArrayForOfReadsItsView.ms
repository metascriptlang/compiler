// @stdout: u8 5 3 i16 -7 2 f64 2.5 view 9 generic 12 empty 0
// @exit: 0

function total<D extends Uint8Array | Readonly<Span<uint8>>>(d: D): int64 {
	let sum: int64 = 0;
	for (const b of d) sum += b as int64;
	return sum;
}

const u = new Uint8Array(3);
u[0] = 1;
u[2] = 4;
let sum: int64 = 0;
let count = 0;
for (const b of u) {
	sum += b as int64;
	count += 1;
}

const s = new Int16Array(2);
s[0] = -9;
s[1] = 2;
let ssum: int64 = 0;
let scount = 0;
for (const x of s) {
	ssum += x as int64;
	scount += 1;
}

const f = new Float64Array(2);
f[0] = 1.25;
f[1] = 1.25;
let fsum = 0.0;
for (const x of f) fsum += x;

const big = new Uint8Array(4);
big[1] = 4;
big[2] = 5;
let vsum: int64 = 0;
for (const b of big.subarray(1, 3)) vsum += b as int64;

let esum = 0;
for (const b of new Uint8Array(0)) esum += 1 + (b as int32);

console.log("u8", sum, count, "i16", ssum, scount, "f64", fsum, "view", vsum, "generic", total(big) + total(u.subarray(0, 2)) + 2, "empty", esum);
