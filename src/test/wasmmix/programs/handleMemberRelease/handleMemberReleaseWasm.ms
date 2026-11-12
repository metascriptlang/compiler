import { Handle } from "std/ffi";

export class Counter {
	n: int32 = 0;

	each(visit: (v: int32) => void): int32 {
		let sum = 0;
		for (let i = 0; i < this.n; i += 1) {
			visit(i);
			sum += i;
		}
		return sum;
	}
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
