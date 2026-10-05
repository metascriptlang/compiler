let steps: int32 = 0;

function scale(n: int32): int32 {
	return n * 2;
}

@inline
export function step(n: int32): int32 {
	steps += 1;
	return scale(n) + steps;
}
