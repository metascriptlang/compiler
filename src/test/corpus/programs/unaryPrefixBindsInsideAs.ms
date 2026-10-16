// Parity program — a prefix operator binds inside `as`, as in TS: `-x as T` casts
// `-x`, so a boundary literal or a negated wide value lands in a narrow type.
//
// @stdout: literal -128 -9223372036854775808 -32768
// @stdout: negate -128 127 255 -100 -128
// @stdout: paren -127 -100
// @stdout: other true number 250
// @stdout: await 7
// @exit: 0

function negInt8(x: int32): int8 {
	return -x as int8;
}

function negUint8(x: int32): uint8 {
	return -x as uint8;
}

function negChain(x: int32): int8 {
	return -x as int16 as int8;
}

function negNonNull(n: int32 | null): int8 {
	return -n! as int8;
}

function negInside(x: int32): int8 {
	return -(x as int8);
}

function notCast(b: boolean): boolean {
	return !b as boolean;
}

function invert(x: uint8): uint32 {
	return ~x as uint32;
}

async function seven(): Promise<int64> {
	return 7;
}

async function awaited(): Promise<int32> {
	return await seven() as int32;
}

const a = -128 as int8;
const b = -9223372036854775808 as int64;
const c = -32768 as int16;
console.log(`literal ${a} ${b} ${c}`);
console.log(`negate ${negInt8(128)} ${negInt8(-127)} ${negUint8(1)} ${negChain(100)} ${negNonNull(128)}`);
console.log(`paren ${negInside(127)} ${-(100 as int8) as int16}`);
const x: int32 = 5;
console.log(`other ${notCast(false)} ${typeof x as string} ${invert(5)}`);
console.log(`await ${await awaited()}`);
