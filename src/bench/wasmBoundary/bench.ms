import {
	Point,
	add,
	add64,
	strLen,
	echo,
	mid,
	sumVec,
	sumSpan,
	makeVec,
	scaleSpan,
	each,
	primes,
} from "./benchWasm";

let sink: float64 = 0;

function bench(name: string, calls: int32, body: () => void): void {
	for (let w = 0; w < 3; w += 1) body();
	const times: float64[] = [];
	for (let r = 0; r < 7; r += 1) {
		const t0 = performance.now();
		body();
		times.push(performance.now() - t0);
	}
	times.sort((a: float64, b: float64): float64 => a - b);
	console.log(`${name} ${(times[3] * 1000000 / calls).toFixed(1)}`);
}

const N = 1000000;
const s16 = "hello wasm world";
let xs: Vec<float32> = [];
for (let i = 0; i < 1000; i += 1) xs.push((i as float32) * 0.25);

bench("add", N, (): void => {
	let s = 0;
	for (let i = 0; i < N; i += 1) s = add(i & 1023, 7);
	sink += s;
});
bench("add64", N, (): void => {
	let s: int64 = 0;
	for (let i = 0; i < N; i += 1) s = add64(i as int64, 7);
	sink += s as float64;
});
bench("strLen16", N, (): void => {
	let s = 0;
	for (let i = 0; i < N; i += 1) s += strLen(s16);
	sink += s;
});
bench("echo16", N, (): void => {
	let s = 0;
	for (let i = 0; i < N; i += 1) s += echo(s16).length;
	sink += s;
});
bench("mid", N, (): void => {
	let s = 0.0;
	for (let i = 0; i < N; i += 1) s += mid({ x: i, y: 2 }).x;
	sink += s;
});
bench("sumVec1k", 10000, (): void => {
	let s: float32 = 0;
	for (let i = 0; i < 10000; i += 1) s += sumVec(xs);
	sink += s as float64;
});
bench("sumSpan1k", 10000, (): void => {
	let s: float32 = 0;
	for (let i = 0; i < 10000; i += 1) s += sumSpan(xs);
	sink += s as float64;
});
bench("makeVec1k", 10000, (): void => {
	let s = 0;
	for (let i = 0; i < 10000; i += 1) s += makeVec(1000).length;
	sink += s;
});
bench("scaleSpan1k", 10000, (): void => {
	for (let i = 0; i < 10000; i += 1) scaleSpan(xs, 1);
});
bench("callback1k", 1000, (): void => {
	let s = 0;
	for (let i = 0; i < 1000; i += 1)
		s += each(1000, (k: int32): int32 => k & 7);
	sink += s;
});
bench("primes2M", 10, (): void => {
	let s = 0;
	for (let i = 0; i < 10; i += 1) s += primes(2000000);
	sink += s;
});
console.log(`sink ${sink > 0}`);
