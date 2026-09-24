export function wrap<T>(x: T): string { return "a:" + String(x); }

export function countdown<T>(tag: T, n: int32): string {
	if (n <= 0) return "a" + String(tag);
	return countdown<T>(tag, n - 1) + String(n);
}
