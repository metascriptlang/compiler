@wasm
export function grow(ref xs: Vec<int32>): void {
	xs.push(xs.length);
}

@wasm
export function countUp(ref n: int32, visit: (x: int32) => void): void {
	visit(n);
	n = n + 1;
}

@wasm
export function lend(visit: (ref x: int32) => void): int32 {
	let x: int32 = 1;
	visit(x);
	return x;
}

@wasm
export function hand(visit: (sink s: string) => void): void {
	visit("handed");
}
