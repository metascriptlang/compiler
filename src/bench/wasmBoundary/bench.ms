import { bench } from "../harness";
import { Handle } from "std/ffi";
import { add, add64, strLen, echo, mid, sumVec, sumSpan, makeVec, scaleSpan, makeBox, scaleBox, each, primes, Counter, peek } from "./benchWasm";

let sink: number = 0;
// With a constant bound, Node's V8 measured wasm-bindgen's add and method rows four times slower than
// warmed (baseline.md, 2026-11-12): keep the bound a variable and the row warmed.
let calls: int32 = 1;
function benchWarmed(name: string, op: () => void): void {
	calls = 1;
	for (let k = 0; k < 400; k += 1) op();
	calls = 1000;
	bench(name, 0, op);
}
const s16 = "hello wasm world";
let xs: Vec<float32> = [];
for (let i = 0; i < 1000; i += 1) xs.push((i as float32) * 0.25);
let fx: float32[1000] = [0];
for (let i = 0; i < 1000; i += 1) fx[i] = (i as float32) * 0.25;

benchWarmed("add x1000", (): void => {
	let s = 0;
	for (let i = 0; i < calls; i += 1) s = add(i & 1023, 7);
	sink += s;
});
benchWarmed("add64 x1000", (): void => {
	let s: int64 = 0;
	for (let i = 0; i < calls; i += 1) s = add64(i as int64, 7);
	sink += s as number;
});
benchWarmed("strLen16 x1000", (): void => {
	let s = 0;
	for (let i = 0; i < calls; i += 1) s += strLen(s16);
	sink += s;
});
benchWarmed("echo16 x1000", (): void => {
	let s = 0;
	for (let i = 0; i < calls; i += 1) s += echo(s16).length;
	sink += s;
});
benchWarmed("mid x1000", (): void => {
	let s = 0.0;
	for (let i = 0; i < calls; i += 1) s += mid({ x: i, y: 2 }).x;
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
const ctr = Handle.retain(new Counter(0));
benchWarmed("method x1000", (): void => {
	let s = 0;
	for (let i = 0; i < calls; i += 1) s = ctr.value().bump(1);
	sink += s;
});
benchWarmed("field x1000", (): void => {
	let s = 0;
	for (let i = 0; i < calls; i += 1) s += ctr.value().n;
	sink += s;
});
benchWarmed("construct x1000", (): void => {
	for (let i = 0; i < calls; i += 1) {
		const c = Handle.retain(new Counter(i & 1023));
		c.release();
	}
});
sink += peek(ctr);
bench("primes 2M", 0, (): void => {
	sink += primes(2000000);
});
box.release();
ctr.release();
if (sink == 0) console.log("sink unused");
