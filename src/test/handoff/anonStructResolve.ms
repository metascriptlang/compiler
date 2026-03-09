// Test: object literal args resolve to parameter's named struct type
// Same-module: works (expectedType propagated from callee param type)
// Cross-module: KNOWN GAP — imported function types may have unresolved
// TypeReferences in typeChildren, causing ObjectLiteral to get anonymous type.

import { compileToC } from "../helpers";

test "same-module object literal resolves to named struct" {
	const src = `
interface Pos {
	line: number;
	column: number;
}

function makePos(p: Pos): Pos {
	return p;
}

export function main(): number {
	const p = makePos({ line: 1, column: 2 });
	return p.line;
}
`;
	const r = compileToC(src);
	assert r.ok;
	// Same-module: literal should get Pos type, not anonymous
	assert !r.value.contains("__anon");
}
