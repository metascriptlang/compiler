// Regression: out/ref/readonly are CONTEXTUAL keywords in a param list.
// `f(out: T)` names the param `out`; `f(out x: T)` makes `out` the modifier on
// `x`. The discriminator is `isIdentLike(peek(1))` (util.ms:201) — modifier only
// when another identifier follows. Before the fix the param parser treated the
// tokens as modifiers unconditionally, so a param literally named `out`/`ref`/
// `readonly` failed to parse ("Unexpected token: }").

import { compileToC } from "../helpers";

test "out as a param name compiles" {
	const src = `
export function pick(out: number): number {
	return out;
}
`;
	const r = compileToC(src);
	assert r.ok;
}

test "ref as a param name compiles" {
	const src = `
export function pick(ref: number): number {
	return ref;
}
`;
	const r = compileToC(src);
	assert r.ok;
}

test "readonly as a param name compiles" {
	const src = `
export function pick(readonly: number): number {
	return readonly;
}
`;
	const r = compileToC(src);
	assert r.ok;
}

test "out modifier still parses (no regression)" {
	const src = `
type MyData = | { value: number } | { name: string };
function setVal(out d: MyData): void {
	d = { value: 42 } as unknown as MyData;
}
`;
	const r = compileToC(src);
	assert r.ok;
}

test "ref modifier still parses (no regression)" {
	const src = `
struct Vec2 { x: number; y: number; }
function scale(ref v: Vec2): void {}
`;
	const r = compileToC(src);
	assert r.ok;
}
