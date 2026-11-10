import { Handle } from "std/ffi";

export class Counter {
	n: int32;
	label: string;

	constructor(start: int32, label: string = "a") {
		this.n = start;
		this.label = label;
	}

	bump(by: int32): int32 {
		this.n += by;
		return this.n;
	}
}

@wasm
export function total(h: Handle<Counter>): int32 {
	return h.value().n;
}
