let kept: (n: int32) => void = (n: int32): void => {};

@wasm
export function listen(visit: (n: int32) => void): void {
	kept = visit;
}

@wasm
export function bump(ref total: int32): void {
	total = total + 1;
	kept(total);
}

@wasm
export function forget(): void {
	kept = (n: int32): void => {};
}
