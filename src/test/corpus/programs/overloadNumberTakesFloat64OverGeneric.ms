// @stdout: float64 float64 float64 float64 | float32 generic
// @stdout: nan found 1
// note: `number` is `float64`, so a `number` argument is an exact match for a `float64` parameter and outranks a generic overload, in either direction and through a method; a `float32` argument keeps its own overload. A Map keyed by `number` finds a NaN key, which only the float overload of its key comparison does.
function pick<T>(a: T): string { return "generic"; }
function pick(a: float64): string { return "float64"; }
function pick(a: float32): string { return "float32"; }
function back<T>(a: T): string { return "generic"; }
function back(a: number): string { return "float64"; }
class Box {
	at<T>(a: T): string { return "generic"; }
	at(a: float64): string { return "float64"; }
}
const n: number = 1.5;
const d: float64 = 2.5;
const f: float32 = 0.5;
console.log(pick(n) + " " + back(d) + " " + new Box().at(n) + " " + pick(d) + " | " + pick(f) + " " + back("s"));
const m = new Map<number, int32>();
const zero: number = 0.0;
const nan = zero / zero;
m.set(nan, 1);
m.set(nan, 2);
console.log((m.has(nan) ? "nan found " : "nan lost ") + String(m.size));
