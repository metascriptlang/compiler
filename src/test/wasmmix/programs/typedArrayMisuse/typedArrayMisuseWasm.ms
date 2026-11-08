class Tagged extends Float32Array {}

let kept: Float32Array | null = null;
let keptBig: Float32Array | null = null;

@wasm
export function keeps(n: int32): Float32Array {
	const out = new Float32Array(n);
	kept = out;
	return out;
}

@wasm
export function tagged(n: int32): Float32Array {
	return new Tagged(n);
}

@wasm
export function shares(n: int32): Float32Array {
	const big = new Float32Array(n * 2);
	keptBig = big;
	return big.subarray(0, n);
}

@wasm
export function fresh(n: int32): Float32Array {
	return new Float32Array(n);
}
