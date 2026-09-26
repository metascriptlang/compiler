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
	return base() + offset();
}

export function pair(scale: int32): Pair {
	return { first: scale, second: scale * 2, third: 0 };
}
