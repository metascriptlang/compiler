let total: int32 = 0;

function add(n: int32): void {
	total += n;
}

@wasm
export function bump(n: int32): void {
	add(n);
}

export function peek(): int32 {
	return total;
}
