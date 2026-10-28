export function walkTree<T>(n: T, depth: int32): int32 {
	n.protoBump(depth);
	let total = depth;
	for (const c of n.protoKids()) total += walkTree(c, depth + 1);
	return total;
}
