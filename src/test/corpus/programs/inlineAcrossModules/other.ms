import { twice, counted, label, Span2, width } from "./lib";

export function fromOther(n: int32): string {
	const s: Span2 = { low: n, high: twice(n) };
	return `${label(s.width())} ${counted(n)}`;
}
