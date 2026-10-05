export struct Row { first: int32; last: int32; }
export struct Span { from: Row; to: Row; }
export type Pair = [int32, string];

export function makeRows(): Row[] {
	const rows: Row[] = [];
	rows.push({ first: 1, last: 2 });
	const current = rows[0];
	rows.push(current);
	rows[1] = { first: 3, last: 4 };
	return rows;
}

export function distinctRows(rows: Row[]): number {
	const seen = new Set<Row>();
	for (const r of rows) seen.add(r);
	return seen.size;
}

export function spanOf(rows: Row[]): Span {
	const s: Span = { from: rows[0], to: rows[rows.length - 1] };
	const copy = s;
	return copy;
}

export function pairOf(rows: Row[]): Pair {
	const pairs: Pair[] = [[rows[0].first, "a"]];
	const p = pairs[0];
	return p;
}
