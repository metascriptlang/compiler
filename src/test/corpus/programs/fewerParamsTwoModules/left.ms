import { pad } from "./lib";

function tag(s: string): string { return s + "<"; }
function wide(f: (s: string, i: int32) => string): string { return f("l", 1); }

export function left(): string {
	const padded = (): int32 => pad(2);
	return `${wide(tag)} ${wide((s: string): string => s + "~")} ${padded()}`;
}
