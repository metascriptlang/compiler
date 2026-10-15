// @stdout: expanded|expanded|expanded|expanded
// @exit: 0

import { Node, NodeKind, bindSym, getType, getTypeImpl } from "std/meta";

class SelfClass {
	next: SelfClass | null = null;
}

interface SelfInterface {
	next: SelfInterface | null;
}

interface Link {
	next: () => Link | null;
}

class ViaFunction {
	link: Link | null = null;
}

class Left {
	right: Right | null = null;
}

class Right {
	left: Left | null = null;
}

function takeClass(props: { ref?: SelfClass | null }): void {}
function takeInterface(props: { ref?: SelfInterface | null }): void {}
function takeFunction(props: { ref?: ViaFunction | null }): void {}
function takeMutual(props: { ref?: Left | null }): void {}

macro probe(e: Node): Node {
	const fn = getType(bindSym(e.name));
	const impl = getTypeImpl((fn as Node).typExprParams[0]);
	return { kind: NodeKind.StringLiteral, line: e.line, column: e.column, value: impl == null ? "null" : "expanded" };
}

console.log([probe(takeClass), probe(takeInterface), probe(takeFunction), probe(takeMutual)].join("|"));
