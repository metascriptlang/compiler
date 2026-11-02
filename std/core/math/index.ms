export { Math, abs, ceil, floor, round, trunc, sign, sqrt, cbrt, pow, exp, expm1, log, log1p, log2, log10, hypot, sin, cos, tan, asin, acos, atan, atan2, sinh, cosh, tanh, asinh, acosh, atanh, random } from "./kernel";
import { Math } from "./kernel";

export function min<T>(this typeof Math, a: T, b: T): T {
	return a < b ? a : b;
}

export function max<T>(this typeof Math, a: T, b: T): T {
	return a > b ? a : b;
}
