// AST Node definitions — re-exported from std/meta/node.ms (source of truth)
// All compiler code imports from here; macro authors import from "std/meta".

export * from "std/meta/node";
export { SymbolFlag } from "std/meta/node";

import { Node } from "std/meta/node";

export function noFieldDecorators(fieldCount: int32): Node[][] {
	const rows: Node[][] = [];
	for (let i = 0; i < fieldCount; i += 1) rows.push([]);
	return rows;
}
