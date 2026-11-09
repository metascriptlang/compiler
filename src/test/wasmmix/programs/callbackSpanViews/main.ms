// @stdout: 9007199254741002 9007199254740995,-9223372036854775808,7
// @stdout: 5,18446744073709551610,9007199254740995
// @stdout: 1.100000023841858 1.100000023841858
// @stdout: caught cut 40,2,3 0.5,2.25
// @stdout: returned 1,2,13 0.5,1.5
// @stdout: 31 1,2,4,8,16
// @stdout: 2 true,true,false 4294967294,4294967295
// @stdout: 0
import {
	wideThrough,
	wideUnsignedThrough,
	realThrough,
	editCaught,
	overlapThrough,
	mixThrough,
	emptyThrough,
} from "./callbackSpanViewsWasm";

console.log(wideThrough((xs: Span<int64>): int64 => {
	xs[0] = xs[0] + 2;
	xs[1] = xs[1] - 1;
	return xs[0] + xs[2];
}));
console.log(wideUnsignedThrough((xs: Span<uint64>): void => {
	xs[0] = xs[0] - 5;
	xs[1] = xs[1] + 2;
}));
console.log(realThrough((xs: Span<float32>): float64 => {
	xs[0] = xs[0] + 0.1;
	return xs[0] as float64;
}));
console.log(editCaught((xs: Span<int32>, fs: Span<float32>): void => {
	xs[0] = 40;
	fs[1] = fs[1] + 0.75;
	throw new Error("cut");
}));
console.log(editCaught((xs: Span<int32>, fs: Span<float32>): void => {
	xs[2] = xs[0] + xs[1] + 10;
}));
console.log(overlapThrough((dst: Span<int16>, src: Readonly<Span<int16>>, all: Readonly<Span<int16>>): int32 => {
	for (let i = 0; i < dst.length; i += 1) dst[i] = (src[i] * 2) as int16;
	let s: int32 = 0;
	for (const x of all) s += x as int32;
	return s;
}));
console.log(mixThrough((bs: Span<boolean>, xs: Span<uint32>, all: Readonly<Span<boolean>>): int32 => {
	bs[0] = true;
	xs[0] = xs[0] - 1;
	xs[1] = 4294967295;
	let on = 0;
	for (const b of all) if (b) on += 1;
	return on;
}));
console.log(`${emptyThrough((a: Span<int64>, b: Readonly<Span<float64>>, c: Span<boolean>, d: Span<uint8>): int32 => {
	let n = 0;
	for (const x of a) n += 1;
	for (const x of b) n += 1;
	return n + (a.length + b.length + c.length + d.length) as int32;
})}`);
