export function count<T>(n: T): int32 {
	let total: int32 = 1;
	for (const c of n.kids()) { total += count(c); }
	return total;
}
