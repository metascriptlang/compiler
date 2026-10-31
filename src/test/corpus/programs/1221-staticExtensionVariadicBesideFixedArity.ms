// @stdout: 2 3 9 2 2 3 9
function mx(this typeof Math, a: float64, b: float64): float64 { return a > b ? a : b; }
function mx(this typeof Math, ...values: float64[]): float64 {
	let m = values[0];
	for (const v of values) { if (v > m) m = v; }
	return m;
}
class Box {}
function top(this self: Box, a: float64, b: float64): float64 { return a > b ? a : b; }
function top(this self: Box, ...values: float64[]): float64 {
	let m = values[0];
	for (const v of values) { if (v > m) m = v; }
	return m;
}
function mn(this typeof Math, a: int32, b: int32): int32 { return a > b ? a : b; }
function mn(this typeof Math, ...values: int32[]): int32 {
	let m = values[0];
	for (const v of values) { if (v > m) m = v; }
	return m;
}
const xs: float64[] = [3, 9, 4];
const ns: int32[] = [3, 9, 4];
const box = new Box();
console.log(Math.mx(1, 2), Math.mx(1, 2, 3), Math.mx(...xs), box.top(1, 2), Math.mn(1, 2), Math.mn(1, 2, 3), Math.mn(...ns));
