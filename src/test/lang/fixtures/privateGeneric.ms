function pendingDedup<T>(x: T | null): int32 {
	return 1;
}

test "nominalInstantiation: same-named generic instantiates in the first module" {
	const w: int32 | null = null;
	assert pendingDedup(w) == 1;
}
