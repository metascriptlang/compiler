// Alias Analysis — reference-aligned path-level alias comparison
//
// Determines if two memory locations (AST node paths) can alias.
// Used by DRC injection to decide move vs copy and self-alias safety.
//
// Reference: alias analysis module (~129 lines)
//
// Core API:
//   aliases(obj, field): AliasKind     — path decomposition + comparison
//   isAnalysableFieldAccess(n, isCursorFn) — ownership gatekeeper
//   deepAliases(dest, ri): boolean     — recursive self-alias check
//   skipConvDfa(n): Node               — strip transparent wrappers

import { Node, NodeKind, Symbol, IdentifierData, MemberExprData, ArrayAccessData, NumberLiteralData, HiddenDerefData, HiddenStdConvData, TypeAssertionData, CallExprData, ObjectLiteralData, ArrayLiteralData, NewExprData, SpreadExprData, BinaryExprData, UnaryExprData, ConditionalExprData, ExprStmtData, TypeKind, SymbolKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { SymbolFlag, hasFlag, makeSymbol } from "../checker/symbol";
import { noneType } from "../checker/types";
import { parseInput } from "../transform/testUtil";

// ===== AliasKind =====

export enum AliasKind {
	Yes,    // definitely same or containing location (x contains x.f)
	No,     // definitely disjoint (x.f vs x.g)
	Maybe,  // cannot determine statically (runtime index: x[i] vs x[j])
}

// ===== skipConvDfa — strip transparent wrappers =====
// Reference: strip transparent wrappers (type conversions, hidden addr/deref) to reach the real node.

export function skipConvDfa(n: Node): Node {
	if (n == null) return n;
	return match (n.kind) {
		NodeKind.TypeAssertion => skipConvDfa((n.data as TypeAssertionData).asExpr),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => skipConvDfa((n.data as HiddenStdConvData).convExpr),
		_ => n,
	};
}

// ===== isAnalysableFieldAccess — ownership gatekeeper =====
// Reference: walk down path operations to root symbol. Check ownership constraints.
// Returns true if DRC can reason about this field/array access.

export function isAnalysableFieldAccess(orig: Node, isCursorFn: (name: string) => boolean): boolean {
	let n = skipConvDfa(orig);
	if (n == null) return false;

	while (n != null) {
		match (n.kind) {
			NodeKind.MemberExpr => {
				n = skipConvDfa((n.data as MemberExprData).object);
			},
			NodeKind.ArrayAccess => {
				n = skipConvDfa((n.data as ArrayAccessData).array);
			},
			NodeKind.HiddenDeref => {
				const inner = skipConvDfa((n.data as HiddenDerefData).expr);
				// Only owned deref (Ref<T>) is analysable, not Ptr<T>
				if (inner != null && inner.nodeType != null && inner.nodeType.kind == TypeKind.Ptr) return false;
				n = inner;
			},
			NodeKind.HiddenAddr => {
				n = skipConvDfa((n.data as HiddenDerefData).expr);
			},
			NodeKind.Identifier => {
				const sym = n.resolvedSym;
				if (sym == null) return false;
				// Not global (module-level)
				if (hasFlag(sym, SymbolFlag.Global)) return false;
				// Params are borrows — not movable
				if (sym.symbolKind == SymbolKind.Parameter) return false;
				// Not a cursor (borrow)
				if (isCursorFn(sym.name)) return false;
				return true;
			},
			_ => { return false; },
		};
	}
	return false;
}

// ===== getRootSym — extract root symbol from a path expression =====
// Walks MemberExpr/ArrayAccess/HiddenDeref chains to the Identifier root.
// Returns the resolvedSym of the root, or null if not found.

export function getRootSym(node: Node): Symbol {
	let n = skipConvDfa(node);
	while (n != null) {
		match (n.kind) {
			NodeKind.Identifier => { return n.resolvedSym; },
			NodeKind.MemberExpr => { n = skipConvDfa((n.data as MemberExprData).object); },
			NodeKind.ArrayAccess => { n = skipConvDfa((n.data as ArrayAccessData).array); },
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { n = skipConvDfa((n.data as HiddenDerefData).expr); },
			_ => { return null as unknown as Symbol; },
		};
	}
	return null as unknown as Symbol;
}

// ===== Path Decomposition =====
// Walk from a node to its root, collecting path components.
// Result: path[0] = leaf (deepest access), path[len-1] = root (Identifier).

function decomposePath(n: Node): Node[] {
	const path: Node[] = [];
	let cur = skipConvDfa(n);
	while (cur != null) {
		match (cur.kind) {
			NodeKind.Identifier => {
				path.push(cur);
				return path;
			},
			NodeKind.MemberExpr => {
				path.push(cur);
				cur = skipConvDfa((cur.data as MemberExprData).object);
			},
			NodeKind.ArrayAccess => {
				path.push(cur);
				cur = skipConvDfa((cur.data as ArrayAccessData).array);
			},
			NodeKind.HiddenDeref => {
				path.push(cur);
				cur = skipConvDfa((cur.data as HiddenDerefData).expr);
			},
			NodeKind.HiddenAddr => {
				// Skip addr — transparent for aliasing
				cur = skipConvDfa((cur.data as HiddenDerefData).expr);
			},
			_ => {
				// Unknown node at path root — push and stop
				path.push(cur);
				return path;
			},
		};
	}
	return path;
}

// ===== aliases — path-level alias comparison =====
// Reference: path-level alias comparison
//
// Truth table:
//   x     -> x      = Yes
//   x     -> x.f    = Yes   (x contains x.f)
//   x.f   -> x      = No    (x.f does NOT contain x)
//   x.f   -> x.f    = Yes
//   x.f   -> x.g    = No    (different fields)
//   x[0]  -> x[1]   = No    (different constant indices)
//   x[i]  -> x[j]   = Maybe (runtime indices)
//   x     -> x[i]   = Yes   (x contains x[i])
//   x[i]  -> x      = No    (x[i] does NOT contain x)

export function aliases(obj: Node, field: Node): AliasKind {
	if (obj == null || field == null) return AliasKind.No;

	// Decompose both nodes into path components
	// path[0] = leaf (deepest), path[len-1] = root (Identifier)
	const objPath = decomposePath(obj);
	const fieldPath = decomposePath(field);

	const objLen = objPath.length;
	const fieldLen = fieldPath.length;

	// If field path is shorter than obj path, field cannot contain obj
	// (e.g. x.f -> x: field is shallower, return No)
	if (fieldLen < objLen) return AliasKind.No;

	// Compare from root outward (root is at end of array)
	let result = AliasKind.Yes;
	let i = 0;
	while (i < objLen) {
		const objNode = objPath[objLen - 1 - i];
		const fieldNode = fieldPath[fieldLen - 1 - i];

		if (objNode.kind != fieldNode.kind) return AliasKind.No;

		match (objNode.kind) {
			NodeKind.Identifier => {
				// Compare by symbol identity
				const objSym = objNode.resolvedSym;
				const fieldSym = fieldNode.resolvedSym;
				if (objSym != null && fieldSym != null) {
					if (objSym != fieldSym) return AliasKind.No;
				} else {
					// Fallback: compare by name
					const objName = (objNode.data as IdentifierData).name;
					const fieldName = (fieldNode.data as IdentifierData).name;
					if (objName != fieldName) return AliasKind.No;
				}
			},
			NodeKind.MemberExpr => {
				// Compare field names
				const objProp = (objNode.data as MemberExprData).property;
				const fieldProp = (fieldNode.data as MemberExprData).property;
				if (objProp != fieldProp) return AliasKind.No;
			},
			NodeKind.ArrayAccess => {
				// Compare indices
				const objIdx = (objNode.data as ArrayAccessData).index;
				const fieldIdx = (fieldNode.data as ArrayAccessData).index;
				if (objIdx.kind == NodeKind.NumberLiteral && fieldIdx.kind == NodeKind.NumberLiteral) {
					const objVal = (objIdx.data as NumberLiteralData).value;
					const fieldVal = (fieldIdx.data as NumberLiteralData).value;
					if (objVal != fieldVal) return AliasKind.No;
				} else {
					// At least one runtime index — downgrade to Maybe
					result = AliasKind.Maybe;
				}
			},
			NodeKind.HiddenDeref => {
				// Derefs are always compatible — no distinction possible
			},
			_ => { return AliasKind.No; },
		};

		i = i + 1;
	}

	return result;
}

// ===== deepAliases — recursive self-alias check =====
// Reference: recursive self-alias check for compound expressions (calls, constructors).
// For compound expressions (calls, constructors), recurse into children.
// For leaf expressions, delegate to aliases().

export function deepAliases(dest: Node, ri: Node): boolean {
	if (ri == null || dest == null) return false;

	return match (ri.kind) {
		NodeKind.CallExpr => {
			const d = ri.data as CallExprData;
			// Check callee (might be a method on dest)
			if (deepAliases(dest, d.callee)) return true;
			for (const arg of d.arguments) {
				if (deepAliases(dest, arg)) return true;
			}
			return false;
		},
		NodeKind.ObjectLiteral => {
			for (const prop of (ri.data as ObjectLiteralData).properties) {
				if (deepAliases(dest, prop)) return true;
			}
			return false;
		},
		NodeKind.ArrayLiteral => {
			for (const elem of (ri.data as ArrayLiteralData).elements) {
				if (deepAliases(dest, elem)) return true;
			}
			return false;
		},
		NodeKind.NewExpr => {
			const d = ri.data as NewExprData;
			if (deepAliases(dest, d.newCallee)) return true;
			for (const arg of d.newArguments) {
				if (deepAliases(dest, arg)) return true;
			}
			return false;
		},
		NodeKind.BinaryExpr => {
			const d = ri.data as BinaryExprData;
			return deepAliases(dest, d.left) || deepAliases(dest, d.right);
		},
		NodeKind.UnaryExpr => deepAliases(dest, (ri.data as UnaryExprData).operand),
		NodeKind.ConditionalExpr => {
			const d = ri.data as ConditionalExprData;
			return deepAliases(dest, d.ternaryCondition)
				|| deepAliases(dest, d.ternaryConsequent)
				|| deepAliases(dest, d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => deepAliases(dest, (ri.data as SpreadExprData).spreadArg),
		NodeKind.TypeAssertion => deepAliases(dest, (ri.data as TypeAssertionData).asExpr),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => deepAliases(dest, (ri.data as HiddenStdConvData).convExpr),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => deepAliases(dest, (ri.data as HiddenDerefData).expr),
		_ => aliases(dest, ri) != AliasKind.No,
	};
}

// ===== Test Helpers =====

function makeTestSym(name: string): Symbol {
	return makeSymbol(name, SymbolKind.Variable, noneType(), false);
}

function getExpr(input: string): Node {
	const result = parseInput(input);
	if (!result.ok) return null as unknown as Node;
	const prog = result.value;
	const d = prog.data as { programStmts: Node[] };
	if (d.programStmts.length == 0) return null as unknown as Node;
	const stmt = d.programStmts[0];
	if (stmt.kind != NodeKind.ExprStmt) return null as unknown as Node;
	return (stmt.data as ExprStmtData).expr;
}

// Test helper: walk a subtree and attach `sym` to every matching Identifier.
// Nested function bodies are scope boundaries (not recursed into).
function attachSymToNodeAlias(node: Node, name: string, sym: Symbol): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier) {
		if ((node.data as IdentifierData).name == name) node.resolvedSym = sym;
		return;
	}
	if (node.kind == NodeKind.FunctionDecl
		|| node.kind == NodeKind.ArrowFunction
		|| node.kind == NodeKind.FunctionExpr) return;
	forEachChild(node, (c: Node): void => { attachSymToNodeAlias(c, name, sym); });
}

// ===== Tests: skipConvDfa =====

test "skipConvDfa passes through identifier" {
	const expr = getExpr("x;");
	const result = skipConvDfa(expr);
	assert result != null;
	assert result.kind == NodeKind.Identifier;
}

test "skipConvDfa null safety" {
	const result = skipConvDfa(null as unknown as Node);
	assert result == null;
}

// ===== Tests: aliases =====

test "aliases: x -> x = Yes" {
	const expr = getExpr("x;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(expr, "x", symX);
	assert aliases(expr, expr) == AliasKind.Yes;
}

test "aliases: x -> x.f = Yes (x contains x.f)" {
	const obj = getExpr("x;");
	const field = getExpr("x.f;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(obj, "x", symX);
	attachSymToNodeAlias(field, "x", symX);
	assert aliases(obj, field) == AliasKind.Yes;
}

test "aliases: x.f -> x = No (field doesn't contain parent)" {
	const obj = getExpr("x.f;");
	const field = getExpr("x;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(obj, "x", symX);
	attachSymToNodeAlias(field, "x", symX);
	assert aliases(obj, field) == AliasKind.No;
}

test "aliases: x.f -> x.f = Yes" {
	const a = getExpr("x.f;");
	const b = getExpr("x.f;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "x", symX);
	assert aliases(a, b) == AliasKind.Yes;
}

test "aliases: x.f -> x.g = No (different fields)" {
	const a = getExpr("x.f;");
	const b = getExpr("x.g;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "x", symX);
	assert aliases(a, b) == AliasKind.No;
}

test "aliases: x[0] -> x[0] = Yes" {
	const a = getExpr("x[0];");
	const b = getExpr("x[0];");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "x", symX);
	assert aliases(a, b) == AliasKind.Yes;
}

test "aliases: x[0] -> x[1] = No (different literal indices)" {
	const a = getExpr("x[0];");
	const b = getExpr("x[1];");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "x", symX);
	assert aliases(a, b) == AliasKind.No;
}

test "aliases: x -> x[i] = Yes (x contains x[i])" {
	const obj = getExpr("x;");
	const field = getExpr("x[i];");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(obj, "x", symX);
	attachSymToNodeAlias(field, "x", symX);
	assert aliases(obj, field) == AliasKind.Yes;
}

test "aliases: x[i] -> x = No (element doesn't contain parent)" {
	const obj = getExpr("x[i];");
	const field = getExpr("x;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(obj, "x", symX);
	attachSymToNodeAlias(field, "x", symX);
	assert aliases(obj, field) == AliasKind.No;
}

test "aliases: x[i] -> x[j] = Maybe (runtime indices)" {
	const a = getExpr("x[i];");
	const b = getExpr("x[j];");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "x", symX);
	assert aliases(a, b) == AliasKind.Maybe;
}

test "aliases: different variables = No" {
	const a = getExpr("x;");
	const b = getExpr("y;");
	const symX = makeTestSym("x");
	const symY = makeTestSym("y");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "y", symY);
	assert aliases(a, b) == AliasKind.No;
}

test "aliases: null = No" {
	assert aliases(null as unknown as Node, null as unknown as Node) == AliasKind.No;
}

test "aliases: x.f.g -> x.f.g = Yes (deep match)" {
	const a = getExpr("x.f.g;");
	const b = getExpr("x.f.g;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "x", symX);
	assert aliases(a, b) == AliasKind.Yes;
}

test "aliases: x.f.g -> x.f.h = No (deep diverge at leaf)" {
	const a = getExpr("x.f.g;");
	const b = getExpr("x.f.h;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(a, "x", symX);
	attachSymToNodeAlias(b, "x", symX);
	assert aliases(a, b) == AliasKind.No;
}

test "aliases: x.f -> x.f.g = Yes (containment at depth 2)" {
	const obj = getExpr("x.f;");
	const field = getExpr("x.f.g;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(obj, "x", symX);
	attachSymToNodeAlias(field, "x", symX);
	assert aliases(obj, field) == AliasKind.Yes;
}

test "aliases: x.f.g -> x.f = No (deeper doesn't contain shallower)" {
	const obj = getExpr("x.f.g;");
	const field = getExpr("x.f;");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(obj, "x", symX);
	attachSymToNodeAlias(field, "x", symX);
	assert aliases(obj, field) == AliasKind.No;
}

// ===== Tests: deepAliases =====

test "deepAliases: x in f(x) = true" {
	const dest = getExpr("x;");
	const call = getExpr("f(x);");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(dest, "x", symX);
	attachSymToNodeAlias(call, "x", symX);
	assert deepAliases(dest, call);
}

test "deepAliases: x not in f(y) = false" {
	const dest = getExpr("x;");
	const call = getExpr("f(y);");
	const symX = makeTestSym("x");
	const symY = makeTestSym("y");
	attachSymToNodeAlias(dest, "x", symX);
	attachSymToNodeAlias(call, "y", symY);
	assert !deepAliases(dest, call);
}

test "deepAliases: x.f vs g(x.g) = false (different fields)" {
	const dest = getExpr("x.f;");
	const call = getExpr("g(x.g);");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(dest, "x", symX);
	attachSymToNodeAlias(call, "x", symX);
	// x.f aliases with x.g? No (different fields) — so deepAliases returns false
	assert !deepAliases(dest, call);
}

test "deepAliases: x in [x, 1] = true" {
	const dest = getExpr("x;");
	const arr = getExpr("[x, 1];");
	const symX = makeTestSym("x");
	attachSymToNodeAlias(dest, "x", symX);
	attachSymToNodeAlias(arr, "x", symX);
	assert deepAliases(dest, arr);
}

test "deepAliases: null = false" {
	assert !deepAliases(null as unknown as Node, null as unknown as Node);
}
