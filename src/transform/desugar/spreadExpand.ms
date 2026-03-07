// Spread Expansion — inlines array literal spreads in call arguments
// Follows reference spread_expand.zig (simplified for lean self-hosted compiler)
//
// fn(...[a, b, c])  →  fn(a, b, c)       (array literal inline)
// fn(x, ...[y, z])  →  fn(x, y, z)       (mixed args)
// fn(...variable)   →  fn(...variable)    (unchanged — dynamic spread)

import {
	Node, NodeKind,
	CallExprData, SpreadExprData, ArrayLiteralData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall } from "../util";
import { firstExprKindAfter, stmtCountAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerSpread(program: Node, ctx: TransformContext): Node {
	walkNode(program, expandSpread);
	return program;
}

function expandSpread(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;
	const d = node.data as CallExprData;

	// Check if any argument is a SpreadExpr
	let hasSpread = false;
	for (const a of d.arguments) {
		if (a.kind === NodeKind.SpreadExpr) {
			hasSpread = true;
		}
	}
	if (!hasSpread) return node;

	// Expand: replace each SpreadExpr with its contents if array literal
	const newArgs: Node[] = [];
	for (const arg of d.arguments) {
		if (arg.kind !== NodeKind.SpreadExpr) {
			newArgs.push(arg);
			continue;
		}
		const sd = arg.data as SpreadExprData;
		// Only expand array literals inline: ...[a, b, c] → a, b, c
		if (sd.spreadArg.kind === NodeKind.ArrayLiteral) {
			const arr = sd.spreadArg.data as ArrayLiteralData;
			for (const elem of arr.elements) {
				newArgs.push(elem);
			}
		} else {
			// Dynamic spread — leave as-is for codegen to handle
			newArgs.push(arg);
		}
	}

	return makeCall(d.callee, newArgs, node.location);
}

// ===== Tests =====
test "no spread passthrough" { expect(firstExprKindAfter("f(a, b);", lowerSpread) === NodeKind.CallExpr); }

test "spread array literal inlined" { expect(firstExprKindAfter("f(...[1, 2]);", lowerSpread) === NodeKind.CallExpr); }

test "non-call unchanged" { expect(firstExprKindAfter("x + y;", lowerSpread) === NodeKind.BinaryExpr); }

test "standalone expr unchanged" { expect(firstExprKindAfter("x;", lowerSpread) === NodeKind.Identifier); }

test "nested call unchanged" { expect(firstExprKindAfter("f(g());", lowerSpread) === NodeKind.CallExpr); }

test "non-expr passthrough" { expect(stmtCountAfter("const x = 1;", lowerSpread) === 1); }
