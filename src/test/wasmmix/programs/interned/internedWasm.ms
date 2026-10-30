let alpha: int32 = 0;
let beta: int32 = 0;
let gamma: int32 = 0;

@wasm
export function hit(s: string): void {
	if (s == "alpha") { alpha = alpha + 1; }
	else if (s == "beta") { beta = beta + 1; }
	else if (s == "gamma") { gamma = gamma + 1; }
}

@wasm
export function count(k: int32): int32 {
	if (k == 0) { return alpha; }
	if (k == 1) { return beta; }
	return gamma;
}
