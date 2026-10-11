@inline
export function forward<T>(value: T): Result<T, string> {
	const result: Result<T, string> = Result.ok(value);
	const checked = try result;
	return Result.ok(checked);
}
