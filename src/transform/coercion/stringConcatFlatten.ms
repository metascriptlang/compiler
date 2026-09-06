// String Concat Flatten — flattens nested string + chains into single concat call
// Follows reference string_concat_flatten.zig + standard reference transform pattern
//
// "hello " + name + "!"   →   msStringConcat(msStringConcat("hello ", name), "!")
// x + y                   →   x + y  (unchanged — can't prove string without type info)
//
// Conservative: only flattens when at least one operand is a StringLiteral.
// This guarantees the + chain is string concatenation (JS/TS coercion rules).
// Chains of length 2 are left as binary (no benefit from flattening).

import { Node, NodeKind, SourceLocation, BinaryExprData, CallExprData, IdentifierData, VariableDeclData } from "../../ast/node";
import { stringType, isStringLike } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent, makeNumber, makeMember } from "../util";
import { firstExprKindAfter, stmtCountAfter, parseInput, getStmts, makeCtx } from "../testUtil";

// ===== Main Entry Point =====

export function lowerStringConcatFlatten(program: Node, ctx: TransformContext): Node {
	walkNode(program, flattenConcat);
	return program;
}

// True for nodes that are unambiguously a string at this transform stage:
// StringLiteral, string-typed value, or an already-flattened concat call.
// Shared predicate used by isStringConcatChain, flattenConcat, coerceToString.
function isStringLeaf(node: Node): boolean {
	if (node.kind == NodeKind.StringLiteral) return true;
	if (node.nodeType != null && isStringLike(node.nodeType)) return true;
	if (node.kind == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		if (cd.callee.kind == NodeKind.Identifier) {
			const cn = (cd.callee.data as IdentifierData).name;
			if (cn == "msStringConcat" || cn == "msStringConcatArr") return true;
		}
	}
	return false;
}

// True if the subtree rooted at `node` is a string-concat chain — i.e. a `+`
// BinaryExpr whose leaves contain at least one string leaf. Pure-numeric `+`
// subtrees (e.g. `len + 1`) return false so the outer flattener keeps them
// atomic. Without this guard, `"data[" + (len + 1)` would split into 3 parts
// and emit `concat("data[","21","1")` = "data[211" instead of the correct
// "data[22" — JS semantics require `(len + 1)` to evaluate numerically (= 22)
// before the surrounding string concat.
function isStringConcatChain(node: Node): boolean {
	if (isStringLeaf(node)) return true;
	if (node.kind == NodeKind.BinaryExpr) {
		const bd = node.data as BinaryExprData;
		if (bd.operator == "+") {
			return isStringConcatChain(bd.left) || isStringConcatChain(bd.right);
		}
	}
	return false;
}

// Collect parts of a + chain, unpacking inner CallExpr nodes that are already
// flattened msStringConcat / msStringConcatArr calls. Needed because the
// walker is bottom-up: inner BinaryExprs get flattened first, so the outer
// level would otherwise see a CallExpr + StringLiteral as just 2 parts. Deep
// collection lets the outer level re-absorb inner flattened chains into a
// single msStringConcatArr call, and keeps stringOpLower's post-flatten
// self-append detection working for chains like `x = x + a + b + c`.
//
// CRITICAL: only descend into an inner `+` BinaryExpr if its subtree is itself
// a string-concat chain (see `isStringConcatChain`). Numeric subtrees must
// stay atomic — splitting `"data[" + (len + 1)` into 3 parts would emit
// "data[211" instead of "data[22".
function collectConcatPartsDeep(node: Node): Node[] {
	const result: Node[] = [];
	const stack: Node[] = [node];
	while (stack.length > 0) {
		const cur = stack.pop();
		if (cur.kind == NodeKind.BinaryExpr) {
			const bd = cur.data as BinaryExprData;
			if (bd.operator == "+" && isStringConcatChain(cur)) {
				stack.push(bd.right);
				stack.push(bd.left);
				continue;
			}
		}
		if (cur.kind == NodeKind.CallExpr) {
			const cd = cur.data as CallExprData;
			if (cd.callee.kind == NodeKind.Identifier) {
				const cn = (cd.callee.data as IdentifierData).name;
				if (cn == "msStringConcat" && cd.arguments.length == 2) {
					stack.push(cd.arguments[1]);
					stack.push(cd.arguments[0]);
					continue;
				}
				if (cn == "msStringConcatArr" && cd.arguments.length >= 1) {
					// args[0] is the count; skip it, push parts in reverse so stack pops in order.
					let i = cd.arguments.length - 1;
					while (i >= 1) {
						stack.push(cd.arguments[i]);
						i -= 1;
					}
					continue;
				}
			}
		}
		result.push(cur);
	}
	return result;
}

function flattenConcat(node: Node): Node {
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	if (d.operator != "+") return node;

	// Deep collect — unpacks inner already-flattened concat calls so the
	// outer level can merge them into one msStringConcatArr.
	const parts = collectConcatPartsDeep(node);

	// Only flatten if at least one part is a string leaf (literal, string-typed,
	// or already-flattened concat call).
	let hasString = false;
	let hasNonString = false;
	for (const p of parts) {
		if (isStringLeaf(p)) hasString = true;
		if (needsCoercion(p)) hasNonString = true;
	}
	if (!hasString) return node;

	const loc = node.location;

	// 2-part: use msStringConcat(a, b) — still need coercion for non-string parts
	if (parts.length == 2) {
		if (!hasNonString) return node; // both strings, binary + is fine
		const args: Node[] = [coerceToString(parts[0], loc), coerceToString(parts[1], loc)];
		const call2 = makeCall(makeIdent("msStringConcat", loc), args, loc);
		call2.nodeType = stringType();
		return call2;
	}

	// 3+ parts: msStringConcatArr(N, a, b, c, ...) — codegen rewrites to
	// stack-local array + msStringConcatArr(arr, N) to avoid the variadic
	// 16-byte struct ABI bug on aarch64-windows-gnu (LLVM #89615).
	const countNode = makeNumber(parts.length, loc);
	const allArgs: Node[] = [countNode];
	for (const p of parts) {
		allArgs.push(coerceToString(p, loc));
	}
	const callN = makeCall(makeIdent("msStringConcatArr", loc), allArgs, loc);
	callN.nodeType = stringType();
	return callN;
}

// Check if a node needs string coercion (is non-string in a string concat context)
function needsCoercion(node: Node): boolean {
	if (node.kind == NodeKind.StringLiteral) return false;
	if (node.kind == NodeKind.NumberLiteral) return true;
	if (node.nodeType != null) {
		if (isStringLike(node.nodeType)) return false;
		// Any non-string typed value needs coercion
		return true;
	}
	return false;
}

// Wrap non-string parts in .toString() calls — builtinLower/extensionMethodLower resolve later
function coerceToString(node: Node, loc: SourceLocation): Node {
	// String leaves (literal, string-typed, or already-flattened concat call)
	// are already strings — no wrapping needed.
	if (isStringLeaf(node)) return node;
	// Emit obj.toString() — pipeline resolves: builtinLower(primitives/enum) → extensionMethodLower(user ext)
	const member = makeMember(node, "toString", loc);
	const call = makeCall(member, [], loc);
	call.nodeType = stringType();
	return call;
}


// ===== Tests =====
test "variable addition unchanged" { assert firstExprKindAfter("x + y;", lowerStringConcatFlatten) == NodeKind.BinaryExpr; }

test "non-binary unchanged" { assert firstExprKindAfter("f();", lowerStringConcatFlatten) == NodeKind.CallExpr; }

test "single stmt passthrough" { assert stmtCountAfter("const x = 1;", lowerStringConcatFlatten) == 1; }

test "non-string binary unchanged" { assert firstExprKindAfter("x * y;", lowerStringConcatFlatten) == NodeKind.BinaryExpr; }

test "identifier unchanged" { assert firstExprKindAfter("x;", lowerStringConcatFlatten) == NodeKind.Identifier; }

test "two-part string stays binary" {
	// "a" + x is only 2 parts — no benefit from flattening
	assert firstExprKindAfter("\"a\" + x;", lowerStringConcatFlatten) == NodeKind.BinaryExpr;
}

// Regression: parenthesized numeric `+` inside a string concat must stay
// atomic. Before the fix, `"data[" + (len + 1) + "]"` flattened to
// `concat("data[", len, 1, "]")` (4 parts) which produced "data[211" at
// runtime. Correct behavior: 3 parts where (len+1) is a single coerced part,
// producing "data[22]" via numeric add.
test "numeric subtree inside string concat stays atomic" {
	const r = parseInput("const len = 21; const a = \"data[\" + (len + 1) + \"]\";");
	assert r.ok;
	const lowered = lowerStringConcatFlatten(r.value, makeCtx());
	const stmts = getStmts(lowered);
	const decl = stmts[stmts.length - 1];
	assert decl.kind == NodeKind.VariableDecl;
	const init = (decl.data as VariableDeclData).initializer;
	assert init.kind == NodeKind.CallExpr;
	const cd = init.data as CallExprData;
	assert (cd.callee.data as IdentifierData).name == "msStringConcatArr";
	// Args: [count, "data[", (len+1).toString(), "]"] — 3 parts not 4.
	assert cd.arguments.length == 4;
	// Middle must be a .toString() call wrapping the BinaryExpr — proves the
	// `(len + 1)` subtree stayed atomic instead of being split.
	const middle = cd.arguments[2];
	assert middle.kind == NodeKind.CallExpr;
	assert (middle.data as CallExprData).callee.kind == NodeKind.MemberExpr;
}

// Mixed inner: `(b + "c")` IS a string-concat chain (has "c"), so the outer
// SHOULD descend through it. Result: 3 atomic parts ["a", b, "c"].
test "string-concat inner subtree gets descended" {
	const r = parseInput("const b = 0; const a = \"a\" + (b + \"c\");");
	assert r.ok;
	const lowered = lowerStringConcatFlatten(r.value, makeCtx());
	const stmts = getStmts(lowered);
	const decl = stmts[stmts.length - 1];
	assert decl.kind == NodeKind.VariableDecl;
	const init = (decl.data as VariableDeclData).initializer;
	assert init.kind == NodeKind.CallExpr;
	const cd = init.data as CallExprData;
	assert (cd.callee.data as IdentifierData).name == "msStringConcatArr";
	// count + 3 parts
	assert cd.arguments.length == 4;
}

// Pure-numeric chain — no string anywhere — must NOT be flattened. Stays as
// nested BinaryExpr `+` so codegen emits arithmetic add, not string concat.
test "all-numeric chain stays binary" {
	const r = parseInput("const a = 1 + 2 + 3;");
	assert r.ok;
	const lowered = lowerStringConcatFlatten(r.value, makeCtx());
	const stmts = getStmts(lowered);
	const decl = stmts[stmts.length - 1];
	assert decl.kind == NodeKind.VariableDecl;
	const init = (decl.data as VariableDeclData).initializer;
	assert init.kind == NodeKind.BinaryExpr;
	assert (init.data as BinaryExprData).operator == "+";
}
