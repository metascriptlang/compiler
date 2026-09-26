export struct Pair {
	first: int32;
	second: int32;
	third: int64;
}

let calls: int32 = 0;

export function base(): int32 {
	return 7;
}

export function tick(): int32 {
	calls += 1;
	return calls;
}

function offset(): int32 {
	return 3;
}

export function value(): int32 {
	const byName = new Map<string, Pair>();
	byName.set("k", { first: 1, second: 2, third: 0 });
	const got = byName.get("k");
	return base() + offset() + (got != null ? got.first : 0);
}

export function pair(scale: int32): Pair {
	return { first: scale, second: scale * 2, third: 0 };
}
