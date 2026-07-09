// Helper module for genericExtProtocol.ms — the generic MUST live in a
// different module than the extension definitions to exercise the
// instantiation-scope (mixin) extension resolution path.

export function walkTree<T>(n: T, depth: float32): void {
	n.protoBump(depth);
	for (const c of n.protoKids()) {
		walkTree(c, depth + 1.0);
	}
}
