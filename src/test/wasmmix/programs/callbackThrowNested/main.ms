// @stdout: 42
// @stdout: true
// @stdout: 2
// @stdout: threw deep
import { relay, permit, deepen } from "./callbackThrowNestedWasm";

function failVoid(message: string): void {
	throw new Error(message);
}

function attempt(run: () => int32): string {
	try {
		return `${run()}`;
	} catch (e) {
		return `threw ${e.message}`;
	}
}

console.log(`${relay("a", (s: string): int64 => 41)}`);
console.log(`${permit("x", (s: string, n: float64): boolean => s == "x" && n > 2)}`);
console.log(attempt(() => deepen(1, (x: int32): void => { deepen(x, (y: int32): void => {}); })));
console.log(attempt(() => deepen(1, (x: int32): void => { deepen(x, (y: int32): void => failVoid("deep")); })));
