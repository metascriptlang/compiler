// A const number converted from an integer is range-checked on that integer: keys() and entries() index and
// narrow through it, a user const indexes through it, a closure that reads it keeps the number, and an int64 at or
// past 2^53 still rounds through the double as the number it holds.
//
// @stdout: 15 17 4 4 9007199254740992 -7

function keysSum(xs: int32[]): int32 {
	let t: int32 = 0;
	for (const k of xs.keys()) t += xs[k];
	return t;
}

function entriesParity(xs: int32[]): int32 {
	let t: int32 = 0;
	for (const [k, x] of xs.entries()) t += x + ((k as int32) & 1);
	return t;
}

function viaConst(xs: int32[], n: int32): int32 {
	const k: number = n;
	return xs[k];
}

function captured(xs: int32[], n: int32): int32 {
	const k: number = n;
	const f = (): int32 => xs[k];
	return f();
}

function roundTrip(v: int64): int64 {
	const k: number = v as number;
	return k as int64;
}

function narrowed(v: int64): int32 {
	const k: number = v as number;
	return k as int32;
}

const xs: int32[] = [1, 2, 3, 4, 5];
console.log(`${keysSum(xs)} ${entriesParity(xs)} ${viaConst(xs, 3)} ${captured(xs, 3)} ${roundTrip(9007199254740993)} ${narrowed(-7)}`);
