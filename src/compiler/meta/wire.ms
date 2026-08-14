// Node wire metadata keys — the ONE list shared by the wire writer
// (nodeToASTLiteral in expand.ms) and the child-traversal reader (the
// msNodeChildCount/At bridges in hostTable.ms). resolvedSym and nodeType
// are node-shaped on the wire (Object with a numeric "kind"), so telling
// children from metadata rests entirely on both sides using this predicate.
// Adding a metadata key to nodeToASTLiteral without adding it here would
// silently turn it into a phantom child.

export function isNodeWireMetaField(name: string): boolean {
	return name === "kind" || name === "line" || name === "column"
		|| name === "endLine" || name === "endColumn"
		|| name === "nodeType" || name === "resolvedSym" || name === "symHandle";
}
