export function joinNames<T>(items: T[]): string {
	const out: string[] = [];
	for (const it of items) { out.push(it.toString()); }
	return out.join(",");
}
