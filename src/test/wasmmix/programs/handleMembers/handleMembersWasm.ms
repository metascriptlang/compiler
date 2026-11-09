import { Handle } from "std/ffi";

export struct Point {
	x: int32;
	y: int32;
}

export class Counter {
	n: int32 = 0;
	label: string = "c";
	at: Point = { x: 1, y: 2 };

	bump(by: int32): int32 {
		this.n += by;
		return this.n;
	}

	get twice(): int32 {
		return this.n * 2;
	}

	set twice(v: int32) {
		this.n = v / 2;
	}

	describe(prefix: string): string {
		return `${prefix}${this.label}=${this.n} at ${this.at.x},${this.at.y}`;
	}

	each(visit: (v: int32) => void): void {
		for (let i = 0; i < this.n; i += 1) visit(i);
	}

	release(): int32 {
		return -this.n;
	}
}

@wasm
export function open(start: int32): Handle<Counter> {
	const c = new Counter();
	c.n = start;
	return Handle.retain(c);
}
