import { count } from "./walk";

export interface Owner { hook: ((o: Owner) => void) | null; }
export struct Cell { owner: Owner | null; }
export struct Slot { owner: Owner | null; }
export interface Scene { rows: Vec<Vec<Cell>>; slots: Vec<Vec<Slot>>; }
export interface Ref { scene: Scene; i: int32; }

export function kids(this r: Ref): Ref[] {
	return r.i > 0 ? [{ scene: r.scene, i: r.i - 1 }] : [];
}

export function size(r: Ref): int32 {
	return count(r);
}

export function owned(slots: Slot[]): int32 {
	let n: int32 = 0;
	for (const s of slots) { if (s.owner != null) n += 1; }
	return n;
}
