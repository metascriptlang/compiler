import { Handle, VecBox } from "std/ffi";

@wasm
export function makeBuf(n: int32): Handle<VecBox<int32>> {
	const b = new VecBox<int32>();
	for (let i = 0; i < n; i += 1) b.items.push(i as int32);
	return Handle.retain(b);
}

@wasm
export function sumBuf(h: Handle<VecBox<int32>>): float64 {
	let s: float64 = 0;
	for (const x of h.value().items) s += x;
	return s;
}
