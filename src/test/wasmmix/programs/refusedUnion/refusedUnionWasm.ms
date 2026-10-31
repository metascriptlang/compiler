@wasm
export function weigh(v: int32 | string): int32 {
	if (typeof v === "number") return v + 1;
	return -1;
}

@wasm
export function pick(flag: boolean): int32 | string {
	if (flag) {
		const n: int32 = 7;
		return n;
	}
	return "one";
}
