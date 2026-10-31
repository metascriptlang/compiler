export enum Color { Red, Green, Blue }

export struct Pixel {
	shade: Color;
	level: int32;
}

@wasm
export function name(c: Color): int32 {
	return c as int32;
}

@wasm
export function next(n: int32): Color {
	const m: int32 = (n + 1) % 3;
	return m as Color;
}

@wasm
export function level(p: Pixel): int32 {
	return p.level + (p.shade as int32);
}
