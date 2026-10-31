// @stdout: 1136
// @stdout: 4,5,6
// @stdout: 12,22
// @stdout: 101
// @stdout: 14995
// @stdout: 13494
// @stdout: 14994
// @stdout: 5995
// @stdout: 10.5
// @stdout: false,true,false,false
// @stdout: true,false
// @stdout: 11050
// @stdout: 47,233,47,55357,56832
// @stdout: 65539,47,233,120
// @stdout: 8194,233,233,47
// @stdout: true
import { bump, weigh, feed, joined } from "./scratchArenaWasm";

function units(s: string): string {
	const out: string[] = [];
	for (let i = 0; i < s.length; i = i + 1) { out.push(`${s.charCodeAt(i)}`); }
	return out.join(",");
}

function ramp(n: int32): Vec<int32> {
	const v: Vec<int32> = [];
	for (let i = 0; i < n; i += 1) { v.push(i % 7); }
	return v;
}

function total(v: Vec<int32>): int32 {
	let s = 0;
	for (const x of v) { s += x; }
	return s;
}

const a: Vec<int32> = [1, 2, 3];
const b: Vec<int32> = [10, 20];
const c: Vec<int32> = [100];
console.log(`${bump(a, 3, (n: int32): int32 => bump(b, 2, (m: int32): int32 => bump(c, 1, (k: int32): int32 => k * 1000)))}`);
console.log(a.join(","));
console.log(b.join(","));
console.log(c.join(","));

const big = ramp(5000);
console.log(`${bump(big, 0, (n: int32): int32 => n)}`);
const mid = ramp(3000);
const inner = ramp(1500);
console.log(`${bump(mid, 2, (n: int32): int32 => bump(inner, 1, (k: int32): int32 => 5))}`);
console.log(`${total(mid)}`);
console.log(`${total(inner)}`);

const ws: Vec<float64> = [0.5, 1.25, 2, 4];
const fl: Vec<boolean> = [true, false, true, true];
const w2: Vec<float64> = [8, 16];
const f2: Vec<boolean> = [false, true];
console.log(`${weigh("abc", ws, fl, 1, (n: int32): int32 => {
	const inside = weigh("ab", w2, f2, 0, (k: int32): int32 => 0);
	return inside == 18 ? 1 : 0;
})}`);
console.log(fl.join(","));
console.log(f2.join(","));

console.log(`${feed(4, (xs: Span<int32>): int32 => {
	const tmp: Vec<int32> = [xs[0], xs[1], xs[2], xs[3]];
	const got = bump(tmp, 0, (n: int32): int32 => n);
	xs[0] = 50;
	return got + tmp[0];
})}`);

console.log(units(joined("", "\u00E9", "\u{1F600}")));
let chunk = "x";
for (let i = 0; i < 15; i += 1) { chunk = chunk + chunk; }
const both = joined(chunk, "\u00E9", chunk);
console.log(`${both.length},${both.charCodeAt(32768)},${both.charCodeAt(32769)},${both.charCodeAt(65538)}`);
let accents = "\u00E9";
for (let i = 0; i < 13; i += 1) { accents = accents + accents; }
const wide = joined(accents, "", "");
console.log(`${wide.length},${wide.charCodeAt(0)},${wide.charCodeAt(8191)},${wide.charCodeAt(8192)}`);

let ok = true;
for (let i = 0; i < 60; i += 1) {
	const v = ramp(i * 97);
	if (bump(v, 0, (n: int32): int32 => n) != total(v)) { ok = false; }
}
console.log(`${ok}`);
