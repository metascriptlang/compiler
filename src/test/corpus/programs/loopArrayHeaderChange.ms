// Loops of element loads and stores may hold an array's length and data in locals; loops that push, pop,
// set `.length`, call something that does, or assign the array variable must see the change next iteration.
// @stdout: fill 0,2,4,6,8,10,12,14 sum=56
// @stdout: alias 1,2,3,4,5,6,7,8
// @stdout: bytes 0,3,6,9,12,15,18,21 sum=84
// @stdout: floats 0.5,1.5,2.5,3.5 sum=8
// @stdout: flags 0,1,0,1,0,1 count=3
// @stdout: wide 3000000000,3000000002,3000000004
// @stdout: matrix 0,1,2,10,11,12,20,21,22 trace=33
// @stdout: breakEarly stopped=4
// @stdout: empty sum=0
// @stdout: pushSource 0,1,2,3,4,5,100 sum=115
// @stdout: pushDest 0,1,2,3 out=0,0,1,1,2,2,3,3
// @stdout: popSource 1,2,3 sum=6 n=3
// @stdout: shrinkAlias 1,2,3 sum=6
// @stdout: setLength 1,2,3,4 sum=10
// @stdout: callGrows 3,4,5,6,7 sum=25
// @stdout: reassign 3 then 7 sum=10
// @stdout: nestedPush 6,12 sum=18
// @stdout: localArrays sum=229

function show(xs: int32[]): string {
	let s = "";
	for (let i = 0; i < xs.length; i++) s += (i > 0 ? "," : "") + xs[i].toString();
	return s;
}

function fill(a: int32[], out: int32[]): void {
	for (let i: int32 = 0; i < a.length; i++) out[i] = a[i] * 2;
}

function copyThroughAlias(a: int32[]): void {
	const b = a;
	for (let i: int32 = 0; i + 1 < a.length; i++) b[i + 1] = a[i] + 1;
}

function sumFloats(a: float64[]): float64 {
	let s: float64 = 0;
	for (let i: int32 = 0; i < a.length; i++) s += a[i];
	return s;
}

function fillBytes(a: uint8[], out: uint8[]): void {
	for (let i: int32 = 0; i < a.length; i++) out[i] = (a[i] * 3) as uint8;
}

function fillFloats(a: float64[], out: float64[]): void {
	for (let i: int32 = 0; i < a.length; i++) out[i] = a[i] + 0.5;
}

function fillFlags(a: boolean[], out: boolean[]): void {
	for (let i: int32 = 0; i < a.length; i++) out[i] = !a[i];
}

function fillWide(a: int64[], out: int64[]): void {
	for (let i: int32 = 0; i < a.length; i++) out[i] = a[i] + 3000000000;
}

function fillMatrix(m: int32[], n: int32): void {
	for (let r: int32 = 0; r < n; r++) {
		for (let c: int32 = 0; c < n; c++) m[r * n + c] = r * 10 + c;
	}
}

function firstAtLeast(a: int32[], limit: int32): int32 {
	let i: int32 = 0;
	while (i < a.length) {
		if (a[i] >= limit) break;
		i++;
	}
	return i;
}

function sumAll(a: int32[]): int64 {
	let s: int64 = 0;
	for (let i: int32 = 0; i < a.length; i++) s += a[i];
	return s;
}

function pushSource(a: int32[]): void {
	for (let i: int32 = 0; i < a.length; i++) {
		if (i == 3) a.push(100);
	}
}

function emit(out: int32[], v: int32): void {
	out.push(v);
	out.push(v);
}

function pushDest(a: int32[], out: int32[]): void {
	for (let i: int32 = 0; i < a.length; i++) emit(out, a[i]);
}

function popSource(a: int32[]): int64 {
	let s: int64 = 0;
	let n: int32 = 0;
	for (let i: int32 = 0; i < a.length; i++) {
		s += a[i];
		n++;
		if (i == 0) a.pop();
	}
	return s * 1000 + n;
}

function shrinkAlias(a: int32[]): int64 {
	const b = a;
	let s: int64 = 0;
	for (let i: int32 = 0; i < a.length; i++) {
		s += a[i];
		if (i == 1) b.length = 3;
	}
	return s;
}

function setLength(a: int32[]): int64 {
	let s: int64 = 0;
	for (let i: int32 = 0; i < a.length; i++) {
		s += a[i];
		if (i == 0) a.length = 4;
	}
	return s;
}

function grow(a: int32[]): void {
	a.push(a[a.length - 1] + 1);
}

function callGrows(a: int32[]): void {
	for (let i: int32 = 0; i < a.length && i < 5; i++) {
		if (a.length < 5) grow(a);
	}
}

function reassign(a: int32[], b: int32[]): string {
	let cur = a;
	let s = "";
	let total: int32 = 0;
	for (let i: int32 = 0; i < 2; i++) {
		total += cur[0];
		s += (i > 0 ? " then " : "") + cur[0].toString();
		cur = b;
	}
	return s + " sum=" + total.toString();
}

function nestedPush(a: int32[], out: int32[]): void {
	for (let r: int32 = 0; r < 2; r++) {
		let acc: int32 = 0;
		for (let i: int32 = 0; i < a.length; i++) acc += a[i];
		out.push(acc * (r + 1));
	}
}

function localArrays(n: int32): int64 {
	const from: int32[] = [];
	for (let i: int32 = 0; i < n; i++) from.push(i + 1);
	const to: int32[] = new Array<int32>(n);
	for (let i: int32 = 0; i < from.length; i++) to[i] = from[i] * 3;
	const noise: int32[] = [];
	for (let i: int32 = 0; i < 64; i++) noise.push(i);
	let s: int64 = 0;
	for (let i: int32 = 0; i < to.length; i++) s += to[i];
	return s + noise.length;
}

const src: int32[] = [];
for (let i: int32 = 0; i < 8; i++) src.push(i);
const dst: int32[] = new Array<int32>(8);
fill(src, dst);
console.log("fill " + show(dst) + " sum=" + sumAll(dst).toString());

const chain: int32[] = [0, 0, 0, 0, 0, 0, 0, 0];
copyThroughAlias(chain);
console.log("alias " + show(chain.map((x) => x + 1)));

const bytes: uint8[] = [];
for (let i: int32 = 0; i < 8; i++) bytes.push(i as uint8);
const bytesOut: uint8[] = new Array<uint8>(8);
fillBytes(bytes, bytesOut);
let byteSum: int32 = 0;
let byteText = "";
for (let i: int32 = 0; i < bytesOut.length; i++) {
	byteSum += bytesOut[i];
	byteText += (i > 0 ? "," : "") + bytesOut[i].toString();
}
console.log("bytes " + byteText + " sum=" + byteSum.toString());

const floats: float64[] = [0, 1, 2, 3];
const floatsOut: float64[] = new Array<float64>(4);
fillFloats(floats, floatsOut);
console.log("floats " + floatsOut.join(",") + " sum=" + sumFloats(floatsOut).toString());

const flags: boolean[] = [true, false, true, false, true, false];
const flagsOut: boolean[] = new Array<boolean>(6);
fillFlags(flags, flagsOut);
let flagText = "";
let flagCount: int32 = 0;
for (let i: int32 = 0; i < flagsOut.length; i++) {
	flagText += (i > 0 ? "," : "") + (flagsOut[i] ? "1" : "0");
	if (flagsOut[i]) flagCount++;
}
console.log("flags " + flagText + " count=" + flagCount.toString());

const wide: int64[] = [0, 2, 4];
const wideOut: int64[] = new Array<int64>(3);
fillWide(wide, wideOut);
console.log("wide " + wideOut.join(","));

const m: int32[] = new Array<int32>(9);
fillMatrix(m, 3);
console.log("matrix " + show(m) + " trace=" + (m[0] + m[4] + m[8]).toString());

console.log("breakEarly stopped=" + firstAtLeast([0, 1, 2, 3, 4, 5], 4).toString());

const none: int32[] = [];
console.log("empty sum=" + sumAll(none).toString());

const ps: int32[] = [0, 1, 2, 3, 4, 5];
pushSource(ps);
console.log("pushSource " + show(ps) + " sum=" + sumAll(ps).toString());

const pd: int32[] = [];
pushDest([0, 1, 2, 3], pd);
console.log("pushDest 0,1,2,3 out=" + show(pd));

const popped = popSource([1, 2, 3, 4]);
console.log("popSource 1,2,3 sum=" + (popped / 1000).toString() + " n=" + (popped % 1000).toString());

console.log("shrinkAlias 1,2,3 sum=" + shrinkAlias([1, 2, 3, 4, 5]).toString());

console.log("setLength 1,2,3,4 sum=" + setLength([1, 2, 3, 4, 5, 6]).toString());

const cg: int32[] = [3];
callGrows(cg);
console.log("callGrows " + show(cg) + " sum=" + sumAll(cg).toString());

console.log("reassign " + reassign([3], [7]));

const np: int32[] = [];
nestedPush([1, 2, 3], np);
console.log("nestedPush " + show(np) + " sum=" + sumAll(np).toString());

console.log("localArrays sum=" + localArrays(10).toString());
