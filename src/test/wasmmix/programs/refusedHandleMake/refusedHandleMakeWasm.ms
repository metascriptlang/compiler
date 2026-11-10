import { Handle } from "std/ffi";

export class Counter {
	n: int32 = 0;
}

@wasm
export function total(h: Handle<Counter>): int32 {
	return h.value().n;
}
