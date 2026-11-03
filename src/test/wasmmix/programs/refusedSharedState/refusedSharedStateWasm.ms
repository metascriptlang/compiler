let total: int32 = 0;

@wasm
export function bump(n: int32): void {
	total += n;
}

export function peek(): int32 {
	return total;
}
