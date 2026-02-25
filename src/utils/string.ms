// String Utilities - DRC-safe string helpers (no indexOf/includes)

export function trim(s: string): string {
	let start = 0;
	let end = s.length;
	while (start < end && charAt(s, start) === " ") { start += 1; }
	while (end > start && charAt(s, end - 1) === " ") { end -= 1; }
	return sliceStr(s, start, end);
}

export function charAt(s: string, i: number): string {
	return sliceStr(s, i, i + 1);
}

export function sliceStr(s: string, start: number, end: number): string {
	return s.slice(start, end);
}

export function findChar(s: string, ch: string): number {
	let i = 0;
	let depth = 0;
	while (i < s.length) {
		const c = charAt(s, i);
		if (depth === 0 && c === ch) return i;
		if (c === "<") { depth += 1; }
		if (c === ">") { depth -= 1; }
		i += 1;
	}
	return -1;
}

export function splitTopLevel(s: string, delim: string): string[] {
	const parts: string[] = [];
	let depth = 0;
	let start = 0;
	let i = 0;
	while (i < s.length) {
		const c = charAt(s, i);
		if (c === "<" || c === "(" || c === "{" || c === "[") { depth += 1; }
		if (c === ">" || c === ")" || c === "}" || c === "]") { depth -= 1; }
		if (depth === 0 && c === delim) {
			parts.push(trim(sliceStr(s, start, i)));
			start = i + 1;
		}
		i += 1;
	}
	if (start < s.length) {
		parts.push(trim(sliceStr(s, start, s.length)));
	}
	return parts;
}
