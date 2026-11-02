@wasm
export function guarded(value: int32, f: (x: int32) => int32): int32 {
	return f(value) + 1;
}

@wasm
export function rethrow(prefix: string, f: () => int32): int32 {
	try {
		return f();
	} catch (e) {
		throw new Error(prefix + e.message);
	}
}

@wasm
export function blow(code: int32): int32 {
	throw new Error(`wasm blew ${code}`);
}

@wasm
export function wild(index: int32): int32 {
	const xs: Vec<int32> = [1, 2];
	return xs[index];
}
