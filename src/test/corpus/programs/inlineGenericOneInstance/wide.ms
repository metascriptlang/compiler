import { viaTry, viaMatch, viaErr } from "./lib";

export function wide(v: int32): string {
	const t = viaTry<uint64>(v, 9 as uint64);
	const m = viaMatch<string>(v, "zero", "other");
	const e = viaErr<uint64>(v, 3 as uint64);
	return `wide ${t.ok ? t.value.toString() : t.error} ${m} ${e.ok ? e.value.toString() : e.error}`;
}
