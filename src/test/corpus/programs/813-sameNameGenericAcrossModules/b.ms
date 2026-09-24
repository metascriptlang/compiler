export function wrap<T>(x: T): string { return "b:" + String(x); }

export function countdown<T>(tag: T, n: int32): string {
	if (n <= 0) return "b" + String(tag);
	return String(n) + countdown<T>(tag, n - 1);
}
