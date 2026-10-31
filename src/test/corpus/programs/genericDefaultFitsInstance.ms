// @stdout: 100 100 300 9 1 100
// note: a generic parameter's default is fitted to each instance's type; a default that fits is passed as that type's value.

function k<T>(x: T, y: T = 100): T {
	return y;
}

function two<A, B>(a: A, b: B, c: B = 300): B {
	return c;
}

function e<T>(x: T, y: T = x): T {
	return y;
}

function m<T>(y: T = 100): T {
	return y;
}

const u: uint8 = 1;
const s: int8 = 1;
const w: int32 = 1;
console.log(k(u), k(s), two(u, w), k(u, 9 as uint8), e(u), m<uint8>());
