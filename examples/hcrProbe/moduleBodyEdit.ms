let count: int32 = 0;
let scale: int32 = 10;

@exportName("hcrProbeBump")
export function bump(): int32 {
	count += 1;
	return count * scale * 2;
}
