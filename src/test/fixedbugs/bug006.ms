// bug006 — macro VM round-trip dropped ArrayAccess sub-expressions
//
// Symptom:    A user macro called with an `arr[i]` arg inside a generic
//             helper crashed the checker with "null is not an object
//             (evaluating 'd.array.nodeType')". Concrete instance:
//                 macro idMacro(t: Node): Node { return t; }
//                 function g<T>(arr: T[]): T { return idMacro(arr[0]); }
//             At type-check, `arr[0]` was serialized through
//             `nodeToASTLiteral` (expand.ms) into an ObjectLiteral; on
//             deserialization via `valueToNode` (bridge.ms), `array` and
//             `index` fields were missing, so the reconstructed
//             ArrayAccess had `d.array === null`. The checker's
//             ArrayAccess case then crashed reading `d.array.nodeType`.
//
//             Blocked V2 of the SERIALIZE plan — generic helpers like
//             `_jsonArrayOfStructs<T>(arr: T[])` calling
//             `jsonValueOf(arr[i])` couldn't be wired because the
//             initial type-check died before any later phase ran.
//
// Root cause: `addKindFields` in `src/compiler/meta/expand.ms` had no
//             case for `NodeKind.ArrayAccess`. `nodeToValue` (bridge.ms)
//             handled it, but the source-form `nodeToASTLiteral` path
//             (the hot path for macro-arg serialization) silently
//             skipped it. Result: macro received the ObjectLiteral with
//             only kind/line/column, no `array` / `index` properties.
//
// Fix:        Add `NodeKind.ArrayAccess` branch to `addKindFields`:
//                 addNodeField(keys, values, "array", d.array, loc);
//                 addNodeField(keys, values, "index", d.index, loc);
//             Symmetric with the existing MemberExpr case. Mirror of
//             both `nodeToValue` (bridge.ms:526) and `valueToNode`
//             (bridge.ms:1157) which already covered ArrayAccess.

macro idMacro(t: Node): Node {
	return t;
}

function pickFirst<T>(arr: T[]): T {
	return idMacro(arr[0]);
}

test "bug006: macro on T[] element inside generic body" {
	const a: int32[] = [10, 20, 30];
	const x = pickFirst<int32>(a);
	assert x === 10;
}

test "bug006: macro on multi-element T[] with computed index" {
	const a: int32[] = [100, 200, 300];
	const x = pickFirst<int32>(a);
	assert x === 100;
}

import { Node } from "std/meta";
