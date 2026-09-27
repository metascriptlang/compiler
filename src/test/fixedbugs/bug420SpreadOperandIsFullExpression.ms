// bug420 — a spread took only a primary expression as its operand
//
// Symptom:    `[...f()]` was rejected as spreading a function value, `[...a.slice(1, 2)]` and
//             `[...groups[0]]` emitted C that did not compile, and a literal made only of
//             spreads was rejected as an empty literal with no element type.
// Root cause: the parser read `...` with parsePrimary, so the call, member and index suffixes
//             applied to the SpreadExpr; the array literal's element type ignored spread sources.
// Fix:        the operand is a full expression (as object spread already was), and a spread
//             contributes its source's element type to the literal's element type.

import { compileToC } from "../helpers";

const header = `
function arr(): int32[] { return [1, 2, 3]; }
const groups: int32[][] = [[1, 2]];
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? "" : c.error;
}

test "bug420: a spread takes a call as its operand" {
	assert errorOf("const s: int32[] = [...arr(), 4];\n") == "";
}

test "bug420: a spread takes a member call and an index as its operand" {
	assert errorOf("const t: int32[] = [1, 2, 3];\nconst w: int32[] = [...t.slice(1, 2), ...groups[0]];\n") == "";
}

test "bug420: a literal made only of spreads takes its element type from them" {
	assert errorOf("const base = arr();\nconst all = [...arr(), ...base];\nconst n: int32 = all[0];\n") == "";
}

test "bug420: a spread of a function value is still refused" {
	assert errorOf("const f: int32[] = [...arr];\n").indexOf("a function value cannot be spread") >= 0;
}
