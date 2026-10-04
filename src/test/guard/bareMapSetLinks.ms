// GUARD-OS bare
// Map and Set build for the bare target: their concurrent-access guard's msMapFatal is the
// freestanding trap. RED MEANS msMapFatal has no freestanding declaration.
export function count(): int32 {
	const m = new Map<int32, int32>();
	m.set(1, 2);
	const s = new Set<int32>();
	s.add(3);
	s.add(3);
	return m.size + s.size;
}
