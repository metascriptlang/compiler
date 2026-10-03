// Parked at inbox card 2026-10-01-match-arm-empty-array-unresolved-type.md
import { compileToC } from "../helpers";

test "generic binding: match arms infer empty array elements" {
	const source = "function f(n: number, xs: number[]): number[] { const result = match (n) { 1 => xs, _ => [] }; return result; } function main(): void { console.log(f(2, [7, 8]).length); }";
	const c = compileToC(source);
	assert c.ok, c.error;
}
