// Test: extension methods with default parameters fill missing args at call site
// When indexOf(this s: string, sub: string, start: number = 0) is called as s.indexOf("x"),
// the codegen must emit msStringIndexOf(s, "x", 0) — not msStringIndexOf(s, "x").

import { compileToC } from "../helpers";

test "indexOf with missing start arg fills default 0" {
	const src = `
export function find(s: string): number {
	return s.indexOf("*");
}
`;
	const r = compileToC(src);
	assert r.ok;
	// Must have 3 args: msStringIndexOf(s, "*", 0)
	assert r.value.contains(", 0)");
}

test "indexOf with explicit start arg passes through" {
	const src = `
export function find(s: string): number {
	return s.indexOf("*", 5);
}
`;
	const r = compileToC(src);
	assert r.ok;
}
