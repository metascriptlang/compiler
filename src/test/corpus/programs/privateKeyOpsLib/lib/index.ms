struct Cell { row: int32; label: string; }
function hash(this c: Cell): int64 { return c.row as int64; }
function `==`(a: Cell, b: Cell): boolean { return a.row == b.row; }

export function countCells(rows: int32[]): string {
	const seen = new Set<Cell>();
	const byRow = new Map<Cell, string>();
	for (const r of rows) {
		const c: Cell = { row: r, label: `r${r}` };
		seen.add(c);
		byRow.set(c, c.label);
	}
	return `${seen.size},${byRow.size},${byRow.get({ row: 2, label: "" }) ?? "none"}`;
}
