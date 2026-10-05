let calls: int32 = 0;

function tally(n: int32): int32 {
	calls += 1;
	return n * 3;
}

export struct Span2 {
	low: int32;
	high: int32;
}

@inline
export function twice(n: int32): int32 {
	return n * 2;
}

@inline
export function counted(n: int32): int32 {
	return tally(n) + calls;
}

@inline
export function label(n: int32): string {
	return "n=" + n.toString();
}

@inline
export function halve(n: int32): int32 {
	if (n % 2 != 0) {
		throw new Error(`odd ${n}`);
	}
	return n / 2;
}

@inline
export function fact(n: int32): int64 {
	return n <= 1 ? 1 : (n as int64) * fact(n - 1);
}

@inline
export function `+`(this a: Span2, b: Span2): Span2 {
	return { low: a.low + b.low, high: a.high + b.high };
}

@inline
export function width(this s: Span2): int32 {
	return s.high - s.low;
}

export function viaLib(n: int32): int32 {
	return twice(n) + 1;
}
