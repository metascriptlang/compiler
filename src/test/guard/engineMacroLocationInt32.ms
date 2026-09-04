// engineMacroLocationInt32 — inside a macro body, the flattened location
// fields (line/column/endLine/endColumn) keep SourceLocation's int32 in the
// ENGINE type view, not a spelled number.
//
// The macro-VM wrapper resolved node.line through a hand-spelled table
// returning numberType(), while std/meta declares SourceLocation
// { line: int32; ... }. Silent until the narrowing rule made it fatal:
// every Neon element/direct helper call went red ("implicit number → int32
// narrowing in 'take' arg N"). Fix: flattenedLocationFieldType reads the
// four names' type off the declared `location` field's struct.
//
// The JSX argument matters: a literal argument eager-folds the macro without
// the engine wrapper, whose ordinary checker already saw int32 — only the
// engine compile took the wrong view. (A same-file fixedbugs pin through
// compileToCWithStd misses it for the same reason; this probe must build
// through the real CLI like any msc build.)

import { Node, NodeKind } from "std/meta";

export macro m(n: Node): Node {
	function take(ln: int32, col: int32): int32 { return ln * 1000 + col; }
	const v = take(n.line, n.column);
	return { kind: NodeKind.NumberLiteral, line: n.line, column: n.column, value: v as number };
}

export macro mEnd(n: Node): Node {
	const ln: int32 = n.endLine;
	const col: int32 = n.endColumn;
	return { kind: NodeKind.NumberLiteral, line: ln, column: col, value: 1 as number };
}

function main(): void {
	console.log(m(<p class="box">hi</p>));
	console.log(mEnd(<p class="box">hi</p>));
	console.log("GUARD-OK");
}
main();
