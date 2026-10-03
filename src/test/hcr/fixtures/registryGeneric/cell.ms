let hits: int32 = 0;

function advance(n: int32): int32 { return n + 1; }

export function echo<T>(value: T): T {
	hits = advance(hits);
	return value;
}

export function hitCount(): int32 { return hits; }
