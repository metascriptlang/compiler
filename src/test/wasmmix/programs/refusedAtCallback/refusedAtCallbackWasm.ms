@wasm
export function each(n: int32, visit: (rows: string[]) => void): void {
	visit(["a", "b"]);
}
