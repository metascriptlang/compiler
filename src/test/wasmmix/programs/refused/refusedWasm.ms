@wasm();

export class Counter {
	value: int32;
	constructor(value: int32) {
		this.value = value;
	}
}

export function read(c: Counter): int32 {
	return c.value;
}
