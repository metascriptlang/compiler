// @stdout: loop 2 at the last part
// @stdout: local 1 at the argument
// @exit: 0
// note: `createNodeAt(K, D, n.location)` reads `n` for the node's line and its column while `D` takes `n` itself, so at comptime `n` moves into `D` and both earlier reads are captured before the move; the line and column reads shared one node, the capture renamed it twice and the second capture read the first before it was declared (`cannot evaluate '$pborrow_N' at comptime: symbol kind is Temp`).

import { Node, NodeKind, createNodeAt } from "std/meta";

function chain(at: Node, parts: Node[]): Node {
	let acc: Node = createNodeAt(NodeKind.ArrayLiteral, { elements: [] }, at.location);
	for (const part of parts) {
		acc = createNodeAt(NodeKind.ArrayLiteral, { elements: [acc, part] }, part.location);
	}
	return acc;
}

function wrapped(at: Node): Node {
	const inner: Node = createNodeAt(NodeKind.StringLiteral, { value: "local" }, at.location);
	return createNodeAt(NodeKind.ArrayLiteral, { elements: [inner] }, inner.location);
}

macro nested(a: Node, b: Node, c: Node): Node {
	const tree = chain(a, [a, b, c]);
	const at = tree.line == c.line && tree.column == c.column ? "at the last part" : `at ${tree.line}:${tree.column}, not the last part`;
	return createNodeAt(NodeKind.StringLiteral, { value: `loop ${tree.elements.length} ${at}` }, a.location);
}

macro single(a: Node): Node {
	const tree = wrapped(a);
	const at = tree.line == a.line && tree.column == a.column ? "at the argument" : `at ${tree.line}:${tree.column}, not the argument`;
	return createNodeAt(NodeKind.StringLiteral, { value: `local ${tree.elements.length} ${at}` }, a.location);
}

console.log(nested(1, 2, 3));
console.log(single(0));
