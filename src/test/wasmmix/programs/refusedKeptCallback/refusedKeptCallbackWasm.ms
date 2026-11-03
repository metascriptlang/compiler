let kept: (n: int32) => void = (n: int32): void => {};

@wasm
export function listen(visit: (n: int32) => void): void {
	kept = visit;
}
