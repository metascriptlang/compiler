export function splitCcFlags(flags: string): Result<string[], string> {
	const result: string[] = [];
	let current = "";
	let quote = "";
	let active = false;
	let i = 0;
	while (i < flags.length) {
		const c = flags.charAt(i);
		if (quote == "'") {
			if (c == "'") quote = "";
			else current = current + c;
			active = true;
			i = i + 1;
			continue;
		}
		if (quote == "\"") {
			if (c == "\"") {
				quote = "";
			} else if (c == "\\" && i + 1 < flags.length) {
				const next = flags.charAt(i + 1);
				if (next == "\"" || next == "\\") {
					current = current + next;
					i = i + 1;
				} else {
					current = current + c;
				}
			} else {
				current = current + c;
			}
			active = true;
			i = i + 1;
			continue;
		}
		if (c == "\"" || c == "'") {
			quote = c;
			active = true;
		} else if (c == " " || c == "\t" || c == "\n" || c == "\r") {
			if (active) {
				result.push(current);
				current = "";
				active = false;
			}
		} else if (c == "\\" && i + 1 < flags.length) {
			const next = flags.charAt(i + 1);
			if (next == " " || next == "\t" || next == "\"" || next == "'" || next == "\\") {
				current = current + next;
				i = i + 1;
			} else {
				current = current + c;
			}
			active = true;
		} else {
			current = current + c;
			active = true;
		}
		i = i + 1;
	}
	if (quote != "") return Result.err("unterminated quote in native compiler flags");
	if (active) result.push(current);
	return Result.ok(result);
}

export function quoteCcArg(arg: string): string {
	let needsQuote = arg.length == 0;
	for (let i = 0; i < arg.length; i++) {
		const c = arg.charAt(i);
		if (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\"" || c == "\\") {
			needsQuote = true;
			break;
		}
	}
	if (!needsQuote) return arg;
	let result = "\"";
	for (let i = 0; i < arg.length; i++) {
		const c = arg.charAt(i);
		if (c == "\"" || c == "\\") result = result + "\\";
		result = result + c;
	}
	return result + "\"";
}
