// @stdout: rotl 3488178117 | sums 2134968277 | mix 1637926418 | cmp 2005
// note: nested uint32 arithmetic gives the same values on every backend: a rotation, sums and differences that wrap, a product of shifted values, a complement and a comparison of a wrapped sum.
function rotl(x: uint32, n: uint32): uint32 { return (x << n) | (x >> (32 - n)); }

let seed: uint32 = 2463534242;
function next(): uint32 {
	seed = seed ^ (seed << 13);
	seed = seed ^ (seed >> 17);
	seed = seed ^ (seed << 5);
	return seed;
}

let rot: uint32 = 0;
let sums: uint32 = 0;
let mix: uint32 = 0;
let cmp: int32 = 0;
for (let i = 0; i < 4000; i++) {
	const a = next();
	const b = next();
	const c = next();
	rot = rot ^ rotl(a ^ b, ((i & 31) + 1) as uint32);
	sums = sums + ((a + b) - (c - a)) + ((b << 7) + (c >> 3));
	mix = mix ^ ((((a << 3) | (b >> 5)) * ((c ^ a) + 1)) + ~(a & b));
	if (a + b < c) cmp += 1;
}
console.log(`rotl ${rot} | sums ${sums} | mix ${mix} | cmp ${cmp}`);
