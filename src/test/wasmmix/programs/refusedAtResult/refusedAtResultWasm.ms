export class Box {
	n: int32;
	constructor(n: int32) {
		this.n = n;
	}
}

@wasm
export function make(n: int32): Box {
	return new Box(n);
}
