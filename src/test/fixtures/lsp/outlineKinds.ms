// LSP outline fixture — one instance of every top-level declaration kind the
// document-symbol collector reports.
//
// Import-free on purpose: testDb builds a db without a std path, so any import
// would raise a resolution error and drown the diagnostics assertion.

export struct Vec2 { x: float64; y: float64; }

export interface Config { name: string; retries: int32; }

export enum Mode { Fast, Slow }

export type Scaler = (v: Vec2) => Vec2;

extern function puts(s: cstring): int32 from "puts";

macro twice(a: int32): int32 { return a; }

const origin: Vec2 = { x: 0.0, y: 0.0 };

const { x, y } = origin;

export function scale(v: Vec2, f: float64): Vec2 {
	when (c) {
		return { x: v.x * f, y: v.y * f };
	}
	return { x: v.x * f, y: v.y * f };
}

test "scale doubles both axes" {
	const v = scale(origin, 2.0);
	assert v.x === 0.0;
	assert v.y === 0.0;
}
