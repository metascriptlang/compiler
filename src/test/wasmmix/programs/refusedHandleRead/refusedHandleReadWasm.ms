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
