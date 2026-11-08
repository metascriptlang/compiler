import { bench } from "../harness";
import { Handle } from "std/ffi";
import { add, add64, strLen, echo, mid, sumVec, sumSpan, makeVec, scaleSpan, makeBox, scaleBox, each, primes } from "./benchWasm";

let sink: number = 0;
const s16 = "hello wasm world";
let xs: Vec<float32> = [];
for (let i = 0; i < 1000; i += 1) xs.push((i as float32) * 0.25);
let fx: float32[1000] = [0];
for (let i = 0; i < 1000; i += 1) fx[i] = (i as float32) * 0.25;

bench("add x1000", 0, (): void => {
	let s = 0;
	for (let i = 0; i < 1000; i += 1) s = add(i & 1023, 7);
	sink += s;
});
bench("add64 x1000", 0, (): void => {
	let s: int64 = 0;
	for (let i = 0; i < 1000; i += 1) s = add64(i as int64, 7);
	sink += s as number;
});
bench("strLen16 x1000", 0, (): void => {
	let s = 0;
	for (let i = 0; i < 1000; i += 1) s += strLen(s16);
	sink += s;
});
bench("echo16 x1000", 0, (): void => {
	let s = 0;
	for (let i = 0; i < 1000; i += 1) s += echo(s16).length;
	sink += s;
});
bench("mid x1000", 0, (): void => {
	let s = 0.0;
	for (let i = 0; i < 1000; i += 1) s += mid({ x: i, y: 2 }).x;
	sink += s;
});
bench("sumVec 1k Array", 0, (): void => {
	sink += sumVec(xs);
});
bench("sumSpan 1k Float32Array", 0, (): void => {
	sink += sumSpan(fx);
});
bench("scaleSpan 1k Float32Array", 0, (): void => {
	scaleSpan(fx, 1);
});
const box = makeBox(1000);
bench("scaleBox 1k held by callee", 0, (): void => {
	scaleBox(box, 1);
});
bench("makeVec 1k", 0, (): void => {
	sink += makeVec(1000).length;
});
bench("callback 1k", 0, (): void => {
	sink += each(1000, (k: int32): int32 => k & 7);
});
bench("primes 2M", 0, (): void => {
	sink += primes(2000000);
});
box.release();
if (sink == 0) console.log("sink unused");
