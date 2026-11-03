import { Handle } from "std/ffi";

export class Counter {
	n: int32 = 0;
}

@wasm
export function open(start: int32): Handle<Counter> {
	const c = new Counter();
	c.n = start;
	return Handle.retain(c);
}

@wasm
export function read(h: Handle<Counter>): int32 {
	return h.value().n;
}
