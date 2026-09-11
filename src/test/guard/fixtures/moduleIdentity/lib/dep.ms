let bumpCount: int32 = 0;

export function bump(): int32 {
	bumpCount = bumpCount + 1;
	return bumpCount;
}
