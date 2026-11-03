import { Handle, value } from "std/ffi";

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
export function keep(h: Handle<Counter>): int32 {
	const g = h;
	return g.value().n;
}
