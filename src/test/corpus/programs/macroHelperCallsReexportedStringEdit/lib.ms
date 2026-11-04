export function plussed(s: string): string {
	return s.replaceAll("-", "+");
}

export function firstStar(s: string): string {
	return s.replace("-", "*");
}

export function padded(s: string): string {
	return plussed(s).padStart(8, ".");
}
