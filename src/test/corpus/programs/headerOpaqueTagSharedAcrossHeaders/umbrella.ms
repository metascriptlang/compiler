import { makeRes, readRes, makeCell, readCell, ResRef, CellRef } from "./all.h";

export function viaUmbrella(v: int32): int32 {
	const r: ResRef = makeRes(v);
	const c: CellRef = makeCell(v + 1);
	return readRes(r) * 10 + readCell(c);
}
