import { Row } from "./row";

function carriedOf(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return 9;
}

function plainOf(k: int32): number | Row {
	if (k == 0) return new Row(7);
	return 9;
}

export function carriedRow(k: int32): Row | null {
	return carriedOf(k) as Row | null;
}

export function plainRow(k: int32): Row {
	return plainOf(k) as Row;
}

export function plainRowOrNull(k: int32): Row | null {
	return plainOf(k) as Row | null;
}
