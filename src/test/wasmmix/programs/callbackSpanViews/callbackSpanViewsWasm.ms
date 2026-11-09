@wasm
export function wideThrough(cb: (xs: Span<int64>) => int64): string {
	let xs: Vec<int64> = [9007199254740993, -9223372036854775807, 7];
	const got = cb(xs);
	return `${got} ${xs.join(",")}`;
}

@wasm
export function wideUnsignedThrough(cb: (xs: Span<uint64>) => void): string {
	let xs: Vec<uint64> = [5, 18446744073709551615, 9007199254740993];
	cb(xs[1..3]);
	return xs.join(",");
}

@wasm
export function realThrough(cb: (xs: Span<float32>) => float64): string {
	let xs: Vec<float32> = [1, 2];
	const got = cb(xs);
	return `${got} ${xs[0]}`;
}

@wasm
export function editCaught(cb: (xs: Span<int32>, fs: Span<float32>) => void): string {
	let xs: Vec<int32> = [1, 2, 3];
	let fs: Vec<float32> = [0.5, 1.5];
	try {
		cb(xs, fs);
	} catch (e) {
		return `caught ${e.message} ${xs.join(",")} ${fs.join(",")}`;
	}
	return `returned ${xs.join(",")} ${fs.join(",")}`;
}

@wasm
export function overlapThrough(
	cb: (dst: Span<int16>, src: Readonly<Span<int16>>, all: Readonly<Span<int16>>) => int32,
): string {
	let v: Vec<int16> = [1, 2, 3, 4, 5];
	const got = cb(v[1..5], v[0..4], v);
	return `${got} ${v.join(",")}`;
}

@wasm
export function mixThrough(
	cb: (bs: Span<boolean>, xs: Span<uint32>, all: Readonly<Span<boolean>>) => int32,
): string {
	let bs: Vec<boolean> = [true, false, false];
	let xs: Vec<uint32> = [4294967295, 1];
	const got = cb(bs[1..3], xs, bs);
	return `${got} ${bs.join(",")} ${xs.join(",")}`;
}

@wasm
export function emptyThrough(
	cb: (a: Span<int64>, b: Readonly<Span<float64>>, c: Span<boolean>, d: Span<uint8>) => int32,
): int32 {
	let a: Vec<int64> = [];
	let b: Vec<float64> = [];
	let c: Vec<boolean> = [];
	let d: Vec<uint8> = [7, 8];
	return cb(a, b, c, d[2..2]);
}
