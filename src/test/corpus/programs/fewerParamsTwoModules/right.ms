import { pad } from "./lib";

function tag(s: string): string { return s + ">"; }
function wide(f: (s: string, i: int32) => string): string { return f("r", 2); }

export function right(): string {
	const padded = (): int32 => pad(3);
	return `${wide(tag)} ${wide((s: string): string => s + "~")} ${padded()}`;
}
