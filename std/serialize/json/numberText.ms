// A number's JSON text appended to the output.

export function appendInt(ref out: string, value: int64): void {
	out += value.toString();
}

export function appendNumber(ref out: string, value: float64): void {
	out += value.toString();
}
