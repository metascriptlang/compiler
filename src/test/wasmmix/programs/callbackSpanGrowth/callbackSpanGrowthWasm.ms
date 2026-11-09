import { Handle } from "std/ffi";

export class Ballast {
	n: int32 = 0;
}

function onDestroy(this b: Ballast): void {
	let big: Vec<int32> = [];
	for (let i = 0; i < b.n; i += 1) big.push(i);
	console.log(`ballast ${big.length}`);
}

@wasm
export function ballast(n: int32): Handle<Ballast> {
	const b = new Ballast();
	b.n = n;
	return Handle.retain(b);
}

@wasm
export function visit(cb: (xs: Span<int32>) => void): int32 {
	let v: Vec<int32> = [1, 2, 3];
	cb(v[0..3]);
	return v[0];
}
