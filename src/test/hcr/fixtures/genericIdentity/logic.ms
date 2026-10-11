import { Box, Plain } from "./box";

const held = new Map<string, unknown>();

function slot<E>(key: string, value: E): Box<E> {
	const found = held.get(key);
	if (found !== undefined) return found as Box<E>;
	const made = new Box<E>(value);
	held.set(key, made);
	return made;
}

export function give(): unknown {
	return new Box<int32>(7);
}

export function probe(): string {
	const i = slot<int32>("int", 2);
	const p = slot<Plain>("plain", new Plain(3));
	const a = slot("anon", { a: 4, s: "x" });
	const t = slot<string>("text", "t");
	return i.v.toString() + " " + p.v.n.toString() + " " + a.v.a.toString() + a.v.s + " " + t.v + " v1";
}
