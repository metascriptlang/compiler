export function fmt(s: string): string;
export function fmt(n: int32): string;
export function fmt(x: string | int32): string {
	if (typeof x == "string") return "s";
	return "n";
}

export function show(this s: string): string;
export function show(this n: int32): string;
export function show(this x: string | int32): string {
	if (typeof x == "string") return "S";
	return "N";
}
