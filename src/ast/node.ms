// AST Node - Abstract Syntax Tree node representation
// Heap-allocated interface for AST nodes

export interface ASTNode {
	kind: string;
	value: string;
}

export function createNode(nodeKind: string, nodeValue: string): ASTNode {
	return { kind: nodeKind, value: nodeValue };
}

export function printNode(node: ASTNode): void {
	console.log("Node: " + node.kind + " = " + node.value);
}
