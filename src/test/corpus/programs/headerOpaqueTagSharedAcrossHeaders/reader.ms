import { readRes, readCell } from "./b.h";
import { ResRef, CellRef } from "./a.h";

export function readBoth(r: ResRef, c: CellRef): string {
	return `${readRes(r)} ${readCell(c)}`;
}
