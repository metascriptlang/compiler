// bug047 — HashMap subscript read `m[k]` crashes checker (variant→union widening)
//
// Symptom:    `const v = m["a"]` (HashMap subscript READ) causes SIGSEGV at
//             checkMemberExpr (addr 0x98, null node.data). The HashMap subscript
//             rewrite in checkExprPass creates a synthetic MemberExpr node via
//             `createNode(NodeKind.MemberExpr, memberData, tok)` where memberData
//             is a NAMED LOCAL typed as the variant `MemberExprData`. Passing a
//             variant-typed local into a union-typed parameter (`data: NodeData`)
//             triggers a raw struct copy between incompatible C layouts — all
//             fields arrive zeroed (property="", object=null).
//
// Root cause: checkExprPass.ms:805 + :1836 declared locals as
//             `const x: MemberExprData = {...}` (variant) then passed to
//             `createNode(kind, data: NodeData, tok)` (union). The parser
//             (core.ms:90) correctly types the same local as `: NodeData` —
//             only these 2 checker sites diverged.
//
// Fix:        Declare both locals as `: NodeData` so the object literal is
//             constructed in the union layout from the start — no widening
//             copy needed. Mirrors Nim's single-case-object discipline:
//             TNode is one type, fields set after construction, no separate
//             variant struct to widen.
//
// Nim parity: Nim's `tables.nim` `table[key]` / `table.getOrDefault(key)`
//             never hits this — Nim uses a single TNode case-object for AST,
//             so variant→union widening doesn't exist as a concept.

import { HashMap } from "std/core/struct";

test "bug047: HashMap subscript read does not crash" {
	const m = new HashMap<string, number>();
	m.set("a", 1);
	m.set("b", 2);
	const v = m["a"];
	assert v === 1;
}

test "bug047: HashMap subscript read multiple keys" {
	const m = new HashMap<string, number>();
	m.set("x", 10);
	m.set("y", 20);
	m.set("z", 30);
	assert m["x"] === 10;
	assert m["y"] === 20;
	assert m["z"] === 30;
}

test "bug047: HashMap subscript in expression context" {
	const m = new HashMap<string, number>();
	m.set("a", 5);
	m.set("b", 7);
	const sum = m["a"]! + m["b"]!;
	assert sum === 12;
}
