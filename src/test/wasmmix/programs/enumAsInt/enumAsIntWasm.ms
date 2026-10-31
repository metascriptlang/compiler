export enum Color { Red, Green, Blue }

export struct Pixel {
	shade: int32;
	level: int32;
}

@wasm
export function name(c: int32): int32 {
	return (c as Color) as int32;
}

@wasm
export function next(n: int32): int32 {
	const m: int32 = (n + 1) % 3;
	return (m as Color) as int32;
}

@wasm
export function level(p: Pixel): int32 {
	return p.level + ((p.shade as Color) as int32);
}
