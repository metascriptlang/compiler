let ticks = 0;

@wasm
export function nested(value: int32, outer: (x: int32) => int32): int32 {
	return outer(value) + 1;
}

@wasm
export function wide(seed: int64, f: (x: int64) => int64): int64 {
	return f(seed) + 1;
}

@wasm
export function permit(a: float64, b: int32, f: (x: float64, y: int32) => boolean): string {
	try {
		return f(a, b) ? "yes" : "no";
	} catch (e) {
		return `denied ${e.message}`;
	}
}

@wasm
export function guardedTick(f: () => void): int32 {
	try {
		f();
	} finally {
		ticks = ticks + 1;
	}
	return 7;
}

@wasm
export function ticksRun(): int32 {
	return ticks;
}

@wasm
export function explode(code: int32): int32 {
	if (code > 0) {
		throw new Error(`wasm blew ${code}`);
	}
	return code;
}

@wasm
export function relay(code: int32, f: (c: int32) => int32): int32 {
	return f(explode(code));
}
