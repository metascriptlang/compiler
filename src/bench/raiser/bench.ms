// Run one binary at a time: a parallel job moves every number.

import { Buffer } from "std/core/buffer";
import { bench } from "../harness";
import { CryptoError, digestSync } from "std/crypto";
import { benchNativeSqrt } from "./benchNative.h";

let sink: number = 0;

class P {
	x: int64;
	y: int64;
	constructor(x: int64, y: int64) {
		this.x = x;
		this.y = y;
	}
}

function fib(n: int64): int64 {
	if (n < 2) return n;
	return fib(n - 1) + fib(n - 2);
}

function inc(x: int64): int64 {
	return x + 1;
}

function makeScale(k: int64): (x: int64) => int64 {
	return (x: int64): int64 => x * k;
}

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

type Circle = { kind: "circle"; r: float64 };
type Rect = { kind: "rect"; w: float64; h: float64 };
type Shape = Circle | Rect;
type NCircle = { kind: 0; r: float64 };
type NRect = { kind: 1; w: float64; h: float64 };
type NShape = NCircle | NRect;
type Tagged = { kind: int32; r: float64; w: float64; h: float64 };

function area(s: Shape): float64 {
	switch (s.kind) {
		case "circle": return s.r * s.r * 3.0;
		case "rect": return s.w * s.h;
	}
}

function nArea(s: NShape): float64 {
	switch (s.kind) {
		case 0: return s.r * s.r * 3.0;
		case 1: return s.w * s.h;
	}
}

function tArea(s: Tagged): float64 {
	switch (s.kind) {
		case 0: return s.r * s.r * 3.0;
		default: return s.w * s.h;
	}
}

const scale = makeScale(3);
const point = new P(0, 0);
const origin = new P(1, 2);
let counter: int64 = 1;

const ints: int64[] = [];
for (let i: int64 = 0; i < 1000; i = i + 1) ints.push(i);

const table = new Map<int64, int64>();
for (let i: int64 = 0; i < 1000; i = i + 1) table.set(i * 7919, i);

const shapes: Shape[] = [];
const nShapes: NShape[] = [];
const tagged: Tagged[] = [];
for (let i = 0; i < 1000; i = i + 1) {
	if (i % 3 == 0) {
		shapes.push({ kind: "circle", r: i });
		nShapes.push({ kind: 0, r: i });
		tagged.push({ kind: 0, r: i, w: 0, h: 0 });
	} else {
		shapes.push({ kind: "rect", w: i, h: 2 });
		nShapes.push({ kind: 1, w: i, h: 2 });
		tagged.push({ kind: 1, r: 0, w: i, h: 2 });
	}
}

const b64k = Buffer.alloc(65536);
for (let i = 0; i < 65536; i++) b64k.set(i, (i * 31 + 7) & 255);

bench("int add loop 1k", 0, () => {
	let s: int64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) s = s + i;
	sink += s as float64;
});
bench("float add loop 1k", 0, () => {
	let acc: float64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) acc = acc + 1.5;
	sink += acc;
});
bench("int to float 1k", 0, () => {
	let acc: float64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) acc = acc + (i as float64);
	sink += acc;
});
bench("fib(25) recursion", 0, () => { sink += fib(25) as float64; });
bench("module variable read 1k", 0, () => {
	let s: int64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) s = s + counter;
	sink += s as float64;
});
bench("module object read 1k", 0, () => {
	let s: int64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) s = s + origin.x;
	sink += s as float64;
});
bench("field read/write 1k", 0, () => {
	const p = point;
	p.x = 0;
	p.y = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) {
		p.x = p.x + p.y;
		p.y = p.y + 1;
	}
	sink += p.x as float64;
});
bench("ms call 1k", 0, () => {
	let s: int64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) s = s + inc(i);
	sink += s as float64;
});
bench("closure call 1k", 0, () => {
	const f = scale;
	let s: int64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) s = s + f(i);
	sink += s as float64;
});
bench("Math.sqrt host call 1k", 0, () => {
	let acc: float64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) acc = Math.sqrt(acc + 2.0);
	sink += acc;
});
bench("user C sqrt call 1k", 0, () => {
	let acc: float64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) acc = benchNativeSqrt(acc + 2.0);
	sink += acc;
});
bench("array push 1k", 0, () => {
	const out: int64[] = [];
	for (let i: int64 = 0; i < 1000; i = i + 1) out.push(i);
	sink += out.length;
});
bench("array index 1k", 0, () => {
	const a = ints;
	let s: int64 = 0;
	for (let i: int32 = 0; i < 1000; i = i + 1) s = s + a[i];
	sink += s as float64;
});
bench("string concat 1k", 0, () => {
	let out = "";
	for (let i: int64 = 0; i < 1000; i = i + 1) out = out + "ab";
	sink += out.length;
});
bench("Map set 1k", 0, () => {
	const m = table;
	for (let i: int64 = 0; i < 1000; i = i + 1) m.set(i * 7919, i);
});
bench("Map get 1k", 0, () => {
	const m = table;
	let s: int64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) {
		const v = m.get(i * 7919);
		if (v !== null) s = s + v;
	}
	sink += s as float64;
});
bench("object alloc 1k", 0, () => {
	let s: int64 = 0;
	for (let i: int64 = 0; i < 1000; i = i + 1) {
		const p = new P(i, i);
		s = s + p.x;
	}
	sink += s as float64;
});
bench("union string tag 1k", 0, () => {
	const xs = shapes;
	let a: float64 = 0;
	for (const s of xs) a = a + area(s);
	sink += a;
});
bench("union number tag 1k", 0, () => {
	const xs = nShapes;
	let a: float64 = 0;
	for (const s of xs) a = a + nArea(s);
	sink += a;
});
bench("int tag record 1k", 0, () => {
	const xs = tagged;
	let a: float64 = 0;
	for (const s of xs) a = a + tArea(s);
	sink += a;
});
bench("sha256 64 KB host bridge", 65536, () => { sink += must(digestSync("sha256", b64k)).length; });

if (sink < 0) console.log("unreachable", sink);
