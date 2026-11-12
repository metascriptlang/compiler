// @stdout: swing 1496 -1496 1496 -1491
// @stdout: near 2147480647 -2147480648 2147480647 -2147480648
// @stdout: negative -1506500 1506500 -1506500 1506500
// @stdout: bumped 100 -1503500
// @stdout: wide 3221225472000 -1501500
// @stdout: int8 120 0 -120
// @stdout: int16 -30000 0
// @stdout: wrapped -1500004 -1502996 -1496 1501500
// note: blocks whose magnitude bound refuses them though every partial sum fits (terms of +-2^30, an accumulator near
// its limit), and blocks of negative terms the bound takes, give the plain loop's total on every backend: the fused
// array sum (indexed, for-of), the sticky block (keys(), a bounded loop, a folded add, subtract or negate), += and -=,
// int8 to int64 sums.

function indexed(xs: int32[], start: int32): int32 {
	let t = start;
	for (let i: int32 = 0; i < xs.length; i++) t += xs[i];
	return t;
}

function minus(xs: int32[], start: int32): int32 {
	let t = start;
	for (const x of xs) t -= x;
	return t;
}

function keyed(xs: int32[], start: int32): int32 {
	let t = start;
	for (const k of xs.keys()) t += xs[k];
	return t;
}

function bounded(xs: int32[], n: int32, start: int32): int32 {
	let t = start;
	for (let i: int32 = 0; i < n; i++) t -= xs[i];
	return t;
}

function bumped(xs: int32[], start: int32): int32 {
	let t = start;
	for (let i: int32 = 0; i < xs.length; i++) t += xs[i] + 1;
	return t;
}

function added(xs: int32[], ys: int32[]): int32 {
	let t: int32 = 0;
	for (const k of xs.keys()) t += xs[k] + ys[k];
	return t;
}

function differed(xs: int32[], ys: int32[], n: int32): int32 {
	let t: int32 = 0;
	for (let i: int32 = 0; i < n; i++) t -= xs[i] - ys[i];
	return t;
}

function negated(xs: int32[]): int32 {
	let t: int32 = 0;
	for (const k of xs.keys()) t += -xs[k];
	return t;
}

function wide(xs: int32[]): int64 {
	let t: int64 = 0;
	for (const x of xs) t += x;
	return t;
}

function small8(xs: int8[]): int8 {
	let t: int8 = 0;
	for (const x of xs) t += x;
	return t;
}

function small16(xs: int16[]): int16 {
	let t: int16 = 0;
	for (const x of xs) t -= x;
	return t;
}

function four(xs: int32[], up: int32, down: int32): string {
	return `${indexed(xs, up)} ${minus(xs, down)} ${keyed(xs, up)} ${bounded(xs, xs.length, down)}`;
}

const big: int32 = 1073741824;
const swing: int32[] = [];
const near: int32[] = [];
const negative: int32[] = [];
const ones: int32[] = [];
for (let k: int32 = 0; k < 3000; k++) {
	swing.push(k % 2 == 0 ? big + k % 7 : -big - k % 5);
	near.push(k % 2 == 0 ? 1000 : -1000);
	negative.push((k % 1000) - 1000);
	ones.push(big);
}
console.log(`swing ${indexed(swing, 0)} ${minus(swing, 0)} ${keyed(swing, 0)} ${bounded(swing, swing.length, 5)}`);
console.log(`near ${four(near, 2147483647 - 3000, -2147483648 + 3000)}`);
console.log(`negative ${four(negative, -5000, 5000)}`);
console.log(`bumped ${bumped([-2147483648, 2147483646, 7, -9], 100)} ${bumped(negative, -5000)}`);
console.log(`wide ${wide(ones)} ${wide(negative)}`);
console.log(`wrapped ${added(swing, negative)} ${differed(swing, negative, 3000)} ${negated(swing)} ${negated(negative)}`);

const twelve: int8[] = [];
const minusTwelve: int8[] = [];
for (let k: int32 = 0; k < 10; k++) {
	twelve.push(12 as int8);
	minusTwelve.push(-12 as int8);
}
const hundreds: int8[] = [];
const thousands: int16[] = [];
for (let k: int32 = 0; k < 2000; k++) {
	hundreds.push((k % 2 == 0 ? 100 : -100) as int8);
	thousands.push((k % 2 == 0 ? 3000 : -3000) as int16);
}
const threes: int16[] = [];
for (let k: int32 = 0; k < 10; k++) threes.push(3000 as int16);
console.log(`int8 ${small8(twelve)} ${small8(hundreds)} ${small8(minusTwelve)}`);
console.log(`int16 ${small16(threes)} ${small16(thousands)}`);
