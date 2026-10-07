let entries: string[] = [];

export function note(text: string): string {
	entries.push(text);
	return entries.join(",");
}
