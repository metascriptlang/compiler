import { E, memberCount } from "./members";

export const base: int32 = 3;

export struct Holder { s: BitSet<E>; tag: int32; }

export function run(): void {
	const h: Holder = { s: E.M19 | E.M1, tag: base };
	console.log(`${sizeof(BitSet<E>)} ${sizeof(Holder)} ${h.s.has(E.M19)} ${h.s.has(E.M5)} ${memberCount()}`);
}
