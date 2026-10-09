export function check(v: int32): Result<int32, string> {
	return v >= 0 ? Result.ok(v) : Result.err("negative");
}

@inline
export function viaTry<T>(v: int32, d: T): Result<T, string> {
	const found = try check(v);
	if (found > 100) {
		return Result.err("big");
	}
	return Result.ok(d);
}

@inline
export function viaMatch<T>(v: int32, d: T, other: T): T {
	return match (v % 3) {
		0 => d,
		_ => other,
	};
}

@inline
export function viaNullish<T>(v: T | null, d: T): T {
	return v ?? d;
}

@inline
export function viaErr<T>(v: int32, d: T): Result<T, string> {
	if (v < 0) {
		return Result.err(`refused ${v}`);
	}
	return Result.ok(d);
}

export function tally(r: Result<int32, string>): string {
	return r.ok ? `ok ${r.value}` : `err ${r.error}`;
}
