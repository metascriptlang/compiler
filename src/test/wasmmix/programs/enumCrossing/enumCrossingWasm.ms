export enum Color { Red, Green, Blue }
export enum Wide { Low = -1, High = 300 }
export enum Tall { Short = 0, Big = 70000 }

export struct Pixel {
	shade: Color;
	level: int32;
	tint: Color | null;
}

@wasm
export function name(c: Color): int32 {
	return c as int32;
}

@wasm
export function next(c: Color): Color {
	const m: int32 = ((c as int32) + 1) % 3;
	return m as Color;
}

@wasm
export function flip(w: Wide): Wide {
	return w == Wide.Low ? Wide.High : Wide.Low;
}

@wasm
export function grow(t: Tall): Tall {
	return t == Tall.Short ? Tall.Big : Tall.Short;
}

@wasm
export function level(p: Pixel): int32 {
	return p.level + (p.shade as int32) + (p.tint != null ? 10 : 0);
}

@wasm
export function paint(c: Color): Pixel {
	return { shade: c, level: 4, tint: c == Color.Red ? null : Color.Blue };
}

@wasm
export function orRed(c: Color | null): Color | null {
	return c == null ? Color.Red : null;
}

@wasm
export function relay(c: Color, f: (x: Color) => Color): Color {
	return f(c);
}
