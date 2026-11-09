import { Handle } from "std/ffi";

export struct Point {
	x: int32;
	y: int32;
}

export class Counter {
	at: Point = { x: 1, y: 2 };
}

@wasm
export function open(): Handle<Counter> {
	return Handle.retain(new Counter());
}
