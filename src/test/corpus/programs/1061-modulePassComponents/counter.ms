export function Counter(start: int32): string {
	return "count=" + start.toString();
}

function Badge(): string {
	return "badge";
}

export function badge(): string {
	return Badge();
}
