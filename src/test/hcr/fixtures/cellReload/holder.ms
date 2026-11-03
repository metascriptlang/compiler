import { Tag } from "./tag";

const kept: Tag[][] = [];

export function keep(tags: Tag[]): void {
	kept.push(tags);
}

export function own(): void {
	kept.push([{ text: "holder" + String(kept.length) }]);
}

export function count(): int32 {
	return kept.length as int32;
}

export function release(): void {
	while (kept.length > 0) kept.shift();
}
