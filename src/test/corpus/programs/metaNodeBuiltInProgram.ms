// @stdout: kinds=1,2 children=2 named=x
// @stdout: dropped=100 last=y99

import { Node, NodeKind, createNodeAt, IdentifierData, SourceLocation } from "std/meta";

function at(line: int32): SourceLocation { return { line, column: 1, endLine: line, endColumn: 2 }; }

function ident(name: string, line: int32): Node {
	return createNodeAt(NodeKind.Identifier, { name } as IdentifierData, at(line));
}

const nodes: Node[] = [ident("x", 1), ident("y", 2)];
const first = nodes[0];
console.log(`kinds=${nodes[0].location.line},${nodes[1].location.line} children=${nodes.length} named=${(first.data as IdentifierData).name}`);

function nameOf(i: int32): string {
	const n = ident(`y${i}`, i);
	return (n.data as IdentifierData).name;
}

let dropped: int32 = 0;
let last = "";
for (let i: int32 = 0; i < 100; i += 1) {
	last = nameOf(i);
	dropped += 1;
}
console.log(`dropped=${dropped} last=${last}`);
