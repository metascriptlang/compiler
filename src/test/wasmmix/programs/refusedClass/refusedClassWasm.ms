export class Counter {
	n: int32 = 0;
}

@wasm
export function open(start: int32): Counter {
	const c = new Counter();
	c.n = start;
	return c;
}
