import { Handle } from "std/ffi";

export class Counter {
	n: int32 = 0;
}

function onDestroy(this c: Counter): void {
	console.log(`destroyed ${c.n}`);
}

@wasm
export function open(start: int32): Handle<Counter> {
	const c = new Counter();
	c.n = start;
	return Handle.retain(c);
}

@wasm
export function bump(h: Handle<Counter>, by: int32): int32 {
	const c = h.value();
	c.n += by;
	return c.n;
}
