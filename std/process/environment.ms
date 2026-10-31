import { asBytes, wellFormedString } from "std/core/string/bytes";
import { utf8StepAt } from "std/core/string/utf8Repair";

function environmentText(text: string): string {
	const bytes = text.asBytes();
	const out: uint8[] = [];
	let at: int64 = 0;
	while (at < bytes.length) {
		const width = utf8StepAt(bytes, at, true);
		if (width < 0) {
			throw new Error("environment text requires well-formed WTF-8");
		}
		if (width == 3 && bytes[at] == 0xed && bytes[at + 1] >= 0xa0) {
			out.push(0xef);
			out.push(0xbf);
			out.push(0xbd);
		} else {
			for (let i: int64 = 0; i < width; i += 1) {
				out.push(bytes[at + i]);
			}
		}
		at += width;
	}
	return wellFormedString(out);
}

export function childEnvironmentPairs(
	variables: Readonly<Map<string, string>>, windows: boolean,
): Result<string[], string> {
	const keys = variables.keys();
	if (windows) { keys.sort(); }
	const seen = new Set<string>();
	const pairs: string[] = [];
	for (const key of keys) {
		if (windows) {
			const upper = key.toUpperCase();
			if (seen.has(upper)) { continue; }
			seen.add(upper);
		}
		if (key.contains("\0")) {
			return Result.err("environment key contains NUL");
		}
		const value = variables.get(key);
		if (value == null) {
			return Result.err("environment value is missing");
		}
		if (value.contains("\0")) {
			return Result.err("environment value contains NUL");
		}
		const pair = key + "=" + value;
		pairs.push(environmentText(pair));
	}
	return Result.ok(pairs);
}
