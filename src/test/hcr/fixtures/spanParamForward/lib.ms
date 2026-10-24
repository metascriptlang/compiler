export function total(xs: Readonly<Span<int32>>): int32 {
	let sum: int32 = 0;
	for (const x of xs) sum += x;
	return sum;
}

export function joined(sep: string, parts: Readonly<Span<string>>): string {
	let out = "";
	for (let i = 0; i < parts.length; i += 1) out += (i == 0 ? "" : sep) + parts[i];
	return out;
}
